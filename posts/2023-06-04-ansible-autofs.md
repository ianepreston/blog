---
title: "Configuring autofs for CIFS mounts with ansible"
date: '2023-06-04'
description: "A user isolated way to mount file shares on a shared Linux host"
layout: post
toc: true
categories: [ansible, Linux]
---

# Introduction

This guide shows how to set up user isolated mounts of CIFS (samba) network shares on
a shared linux VM. Each user will get folders under `/mnt/<user>` that they authenticate
to using kerberos. In this document I'm assuming that users are members of a group and that
each group all should have access to the same shares. We'll further assume you've got
a fact set in your playbook that maps each user to their corresponding group. If you
need guidance on that you can see [this post](2023-06-04-ansible-ad-users.md).

This is a nice way of attaching file shares because it ensures users don't need elevated
privileges to access file shares (although an administrator has to configure it for them)
and that creating a share for one user doesn't inadvertently expose it to others. For a
fully user level way of attaching file shares you can use [gio](https://man.archlinux.org/man/gio.1)
but I found it extremely flaky and annoying to use, so if you can handle having an administrator
configure the share mount points for users I would recommend this approach.

# Variable format

Somewhere in your playbook (in my case I set it in the variables folder of the role
I was using, but putting in as a host variable or somewhere else may be more appropriate
for your use case) we need a variable for each group that contains a list of associated
shares. Something like this:

```yml
example_group1:
  - local_share_name: share1
    full_share_path: "//fileshare.example.com/share1"
  - local_share_name: share2
    full_share_path: "//fileshare.example.com/share2"

example_group2:
  - local_share_name: share3
    full_share_path: "//fileshare.example.com/share3"
```

# Basic setup

In this stage we will ensure pre-requisite software is installed on the host (assuming
Ubuntu here, you will have to modify for other distros), and that the mount point folder
for each user has been created:

```yml
- name: Install autofs
  ansible.builtin.apt:
    pkg:
      - autofs
      - cifs-utils
      - keyutils

- name: Create base file share mount point
  ansible.builtin.file:
    path: "/mnt/{{ item.user }}"
    state: directory
    owner: "{{ item.user }}"
    group: "domain users@example.com"
    mode: "0700"
  with_items: "{{ users_dict }}"

- name: Start and enable the autofs service
  ansible.builtin.systemd:
    name: autofs
    state: started
    enabled: true
```

Where `users_dict` looks like what I created in [this post](2023-06-04-ansible-ad-users.md).
You will also have to modify the `group` variable to be appropriate for your environment.

I actually have the autofs service start task at the bottom of this play in my case, but
thematically it makes more sense here.

# Populate auto.master

```yml
- name: populate auto.master with entries for each users' configs
  ansible.builtin.template:
    src: auto.master.j2
    dest: /etc/auto.master
    owner: root
    group: root
    mode: '0644'
```

Each user needs an entry in `/etc/auto.master` that points to a config file (which we'll
set in the next phase) with all their specific mount points. Using the template task
and the template below we can accomplish this:

```jinja
# {{ ansible_managed }}
{% for user in users_dict %}
/mnt/{{ user.user }} /etc/auto.sambashares-{{ user.user }} --timeout=30 --ghost
{% endfor %}
```

Each user gets a point below the `/mnt/<user>` folder we created in the basic setup,
we point to a config file for them, set a timeout so the fileshare will not stay connected
if users aren't using it and then we add the `--ghost` flag so that all mount points
get a directory created, even if they're not currently attached. See
[here](https://learn.redhat.com/t5/Platform-Linux/Halloween-tip-of-the-day-Using-autofs-with-the-ghost-option/td-p/2326)
for further docs.

# Populate user level share specs

```yml
- name: Populate user specific share mounts
  ansible.builtin.template:
    src: auto.sambashares.j2
    dest: "/etc/auto.sambashares-{{ item.user }}"
    owner: root
    group: root
    mode: '0644'
  with_items: "{{ users_dict }}"
```

Again we're populating a template, but this time we're doing one for each user. As with
above, most of the magic happens in the template itself:

```jinja
# {{ ansible_managed }}
{% set shares = lookup('vars', item.group | replace('-', '_')) %}
{% for share in shares %}
{{ share.local_share_name }} -fstype=cifs,rw,sec=krb5,uid=${UID},cruid=${UID} :{{ share.full_share_path }}
{% endfor %}
```

The `replace` step is because a lot of the groups I was using had a `-` in their name,
which you can't have in an ansible variable so I map the `-` to an `_`. We can then
use that to refer to the variable described at the top of this post for whichever
group the particular user happens to be in. Then we just iterate through all the shares
defined and create a folder under `/mnt/<user>/<local_share_name>` that maps to `full_share_path`
and will be authorized with kerberos.

# Conclusion

Autofs and ansible are a pretty nice way to set up a bunch of users with consistent file
shares securely on a shared host or multiple hosts.