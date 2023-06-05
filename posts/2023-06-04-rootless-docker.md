---
title: "Configuring Rootless docker with ansible"
date: '2023-06-04'
description: "Rootless docker is nice and more secure, but it's a hassle to set up"
layout: post
toc: true
categories: [docker, Linux]
---

# Introduction

This is a write up summarizing the process I went through at work to configure Linux
hosts with [rootless docker](https://docs.docker.com/engine/security/rootless/). After
figuring out the manual way to do things I further automated it with an ansible playbook,
as there's a lot of per-user stuff you have to do that quickly becomes untenable to do
manually, even if you're only doing it on one host, and really out of hand if you have
multiple hosts.

This document will outline the key steps for configuring rootless docker for users and
the associated ansible tasks required for it. I'm not going to show every aspect of
setting up ansible like creating the inventory of hosts, just the components that are
specific to rootless docker.

I previously documented the manual approach I took while figuring all this out in
[this post](2022-12-30-rootless-docker.md).

## Why rootless docker?

Briefly, let me describe what motivated this approach. At work we have a number of teams
that want to use docker, either for a development environment in
[devcontainers](https://code.visualstudio.com/docs/devcontainers/containers), building
containers for deployment, or both. All of our laptops run Windows, so the immediate
obvious solution would be to install [docker desktop](https://www.docker.com/products/docker-desktop/).
Unfortunately, that installation required turning on some services that we had disabled
for security reasons, so we were not able to proceed with that approach. The next option
would be docker on a remote Linux host. The traditional way of installing docker means
that anyone who has access to work with docker effectively has root access to the system
they're running it on. This obviously presents a security issue on a shared machine, and
the cost and complexity of giving every user their own VM was not practical, particularly
for users that required GPUs for some of their workloads. Given these constraints, I set
out to configure rootless docker so that multiple users could securely share a remote
Linux instance and work in docker without security concerns. This has the added benefit
of allowing users to do things like stop all their running containers with
`docker container stop $(docker container ls -aq)` without stopping everyone else's.

# Install the docker engine

This part of the playbook is the same whether or not you're going to do rootless, but
I'll include it for completeness. We're basically following the
[docker install instructions](https://docs.docker.com/engine/install/) in ansible format.
This particular playbook assumes the host OS is Ubuntu, and will need slight modification
for other distributions:

```yml
- name: Install docker pre-requisites
  ansible.builtin.apt:
    pkg:
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
      # Necessary for rootless installer
      - uidmap

- name: Add docker gpg key
  ansible.builtin.shell: |
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg
  args:
    creates: "/etc/apt/keyrings/docker.gpg"

- name: add docker repository to apt
  apt_repository:
    repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    state: present

- name: Install docker
  ansible.builtin.apt:
    pkg:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-compose-plugin
```

Figuring out how to correctly create the GPG key and the associated apt repository was
a bit tricky. Originally I wanted to use [apt_key](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_key_module.html)
but it's been deprecated due to security concerns. For whatever reason using the alternate
examples provided in the docs with [get_url](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html)
didn't seem to work. I'm not totally clear on what the `gpg --dearmor` is doing in the
above playbook, but it's definitely necessary. Fortunately it's easy to make that script
idempotent with the `creates` argument for the task.

# Perform rootless docker setup

This is where the meat of the install goes. This assumes you've got a list somewhere
of all the users you want to configure for rootless docker and their UIDs. If your users
are all members of AD groups then you can do something like what I document in
[this post](2023-06-04-ansible-ad-users.md) to get that fact set in your playbook.

## Create /etc/subuid and /etc/subgid

The next thing we do is configure which UID and GID ranges on the host machine should
be uniquely mapped for each user into their docker daemon. We want to reserve a range
of IDs for each user so that permissions for a user within a container do not provide
privilege escalation outside the container. Just as an aside, in a rootless runtime,
UID 0 or root inside the container maps to the user that is running docker and their UID
outside the container, so be sure to run your containers as root if you have any volumes
bind mounted and don't want to have to deal with weird permission issues.

```yml
- name: apply subuid and subgid settings for mapping
  ansible.builtin.template:
    src: subid.j2
    dest: /etc/{{ item }}
    owner: root
    group: root
    mode: '0644'
  with_items:
    - "subuid"
    - "subgid"
```

The task itself is quite straightforward, where the magic happens is in the template:

```jinja
# {{ ansible_managed }}
{% for user in users_dict %}
{{ user.user }}:{{100000 + (loop.index0 * 65536)}}:65536
{% endfor %}
```

As mentioned, for each user we want a non-overlapping range of UIDs. In the docker
docs they give each user a range of 65536 UIDs to use and start at 100000, which we
reproduce here. The format of each entry is `username:start UID range:size of range`.
We ensure this is non overlapping by multiplying the index of the loop we're on by the
size of the UID range. `/etc/subuid` and `/etc/subgid` have the exact same format so in
the playbook we just apply the same template to both files.

## Stop the root level docker service

This will conflict with the user level docker service, so we have to ensure it's stopped:

```yml
- name: Make sure the root level docker service is stopped and disabled
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: stopped
    enabled: false
  with_items:
    - "docker.service"
    - "docker.socket"
```

## Create home directories for each user

This is potentially being run on a newly created machine with users from Active Directory.
Because of this, the users may not have a home directory created for them before they log
in, so we have to ensure it's created in order to copy later user level config files into
it. We also create an ansible temp directory at this stage to suppress a warning.

I'm not totally sure the home directory creation needs to be done as a separate task,
since the temp directory will create all parent folders necessary, but I wrote the first
task before I realized I needed the second, and it's nice to separate out the reasons
for each step.

```yml
- name: Make sure home directory exists
  ansible.builtin.file:
    path: "/home/{{ item.user }}"
    owner: "{{ item.user }}"
    group: "domain users@example.com"
    state: directory
    mode: '0755'
  with_items: "{{ users_dict }}"

- name: Make sure the ansible temp dir exists for each user
  ansible.builtin.file:
    path: "/home/{{ item.user }}/.ansible/tmp"
    owner: "{{ item.user }}"
    group: "domain users@example.com"
    state: directory
    mode: '0700'
  with_items: "{{ users_dict }}"
```

Your value for `group` will likely be different, but you get the idea.

## Create an entry in /etc/passwd

This is another feature of using domain users. Domain users don't appear to automatically
get an entry in `/etc/passwd` that lists things like their default shell. Even though
users may have their default shell set to `bash` by `PAM` or whatever else, VS code
doesn't seem to recognize this without an `/etc/passwd` record, which causes it to try
and run devcontainers through `/bin/sh`, which means your `~/.bashrc` doesn't get loaded,
which causes problems you'll see in future steps. The TLDR is we want to manually create
a record for each user in `/etc/passwd`. If you're not dealing with users managed by AD
then you can probably skip all this.

```yml
- name: Get lines for /etc/passwd
  ansible.builtin.shell: |
    getent passwd {{ item.user }}
  register: getentstask
  with_items: "{{ users_dict }}"
  changed_when: false

- name: Filter results to just stdout
  set_fact: 
    getents: "{{getentstask.results | map(attribute='stdout')}}"

- name: Make sure there's a line in /etc/passwd
  ansible.builtin.lineinfile:
    path: /etc/passwd
    line: "{{ item }}"
  with_items: "{{ getents }}"
```

This feels a bit weird. In theory running `getent passwd <user>` should just be returning
exactly what's in `/etc/passwd` for that user to `stdout` so taking that result from
`stdout` and putting it in `/etc/passwd` feels a bit circular, but it's necessary for AD
users.

## Turn on linger for users

Turning this on allows user level services like rootless docker to persist when the user
is not logged in. If we want users to be able to host small apps with docker from their
user account for testing without being logged in all the time this is handy

```yml
- name: Turn on linger for all users
  become: true
  ansible.builtin.command:
  args:
    cmd: "loginctl enable-linger {{ item.user }}"
    creates: "/var/lib/systemd/linger/{{ item.user }}"
  with_items: "{{ users_dict }}"
```

Don't ask me why I used `command` here and `shell` in the previous one. I should really
just use `shell` all the time.

## Run the installer

```yml
- name: Run the rootless docker installer
  become: true
  become_user: "{{ item.user }}"
  ansible.builtin.command: 
  args:
    cmd: dockerd-rootless-setuptool.sh install
    creates: "/home/{{ item.user }}/.docker/config.json"
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ item.uid }}"
  with_items: "{{ users_dict }}"
```

Note the call to `become_user`, that's important. You can't run the install script
as root and tell it to do it for a specific user, at least I couldn't figure out how,
so we need to actually run this as the user we want. Also note that setting `XDG_RUNTIME_DIR`
is necessary for successful completion of the install and requires you to know the UID
of the user you're configuring. Failing to set this variable will result in the script
still running but the daemon and user service not actually being installed.

## Set bashrc to export the docker socket

At this point users have docker installed and should be able to run `docker run hello-world`
or some other similar test. We do have to take an extra step to get it to work with VS
code though, and that's setting an environment variable that points to the docker socket.
This is the part I mentioned above that won't work if you don't have your default shell
set to bash in `/etc/passwd`.

```yml
- name: Make sure bashrc exports the docker socket
  become: true
  become_user: "{{ item.user }}"
  ansible.builtin.lineinfile:
    path: "/home/{{ item.user }}/.bashrc"
    line: "export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock"
    create: true
  with_items: "{{ users_dict }}"
```

# Conclusion

Setting up rootless docker for an individual user isn't a ton of work, but trying to
scale that to multiple users on multiple machines begs for automation or else you're
pretty much guaranteed to waste time and make errors. The steps above should help you
set up rootless docker for users with ansible.