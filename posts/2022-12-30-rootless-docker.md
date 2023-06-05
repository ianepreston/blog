---
aliases:
- /configuration/linux/2022/12/30/rootless-docker
categories:
- configuration
- linux
date: '2022-12-30'
description: How can multiple users share a host for docker without a security nightmare?
layout: post
title: Setting up rootless docker
toc: true

---

# Introduction

This post covers something that I did for work that I thought might be of more general
interest. We have a number of developers that want to build and work in docker containers.
Due to security constraints we can't install WSL and docker desktop on our laptops, so
some remote development solution is required. We don't have kubernetes or anything fancy
in our environment, so the initial solution was to just provision an Ubuntu VM and give
everyone a login and access to the docker group. Unfortunately there are some major
usability and security issues with this approach. Basically, since giving access to docker
is essentially giving root access to the machine, developers can see and access each other's
containers and files. From a security perspective this is obviously no good. Even from a
usability perspective it means there's constant risk of inadvertently tripping over another
developer's work, and cleaning up your old images and containers has to be done with a lot
more care. To address this issue I decided to look into [rootless docker](https://docs.docker.com/engine/security/rootless/).

I'm going to try a different approach with this blog. The next section will be a lightly
edited transcription of all the things I tried (including failures, dead ends, and
dumb mistakes). The following section will be a TLDR summary of what you actually need to
do to get this working.

# Live blogging step by step discovery

This experiment started with a vanilla Ubuntu 22.04.1 VM. I had a user with sudo permission,
`dockertestian` and then created two users without any special credentials, `dockertesta`
and `dockertestb`.

First I tried installing docker with `sudo apt install docker`, but that was lacking
some of the additional features required for rootless docker. It's possible that
I could have found what I needed in the regular Ubuntu repository, but after being
thwarted there, I switched to the [docker docs](https://docs.docker.com/engine/install/ubuntu/)
method and followed their instructions through.

Following the rootless install docs, I disabled the system level docker daemon, and then
as each of my regular users I logged in and ran the rootless install script (described in
the docker docs). I had to log out and log back in but beyond that I was able to
run `docker run hello-world` without issue. I noticed that when I ran this for the second
user it had to download the `hello-world` image again, which was a good sign for actual
isolation.

After running the rootless install script I was given a notice that I might have to modify
my `~/.bashrc`, but I left that alone for a pure test at first.

The next step was to see if I could use VS Code and [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers). Initially this didn't work, as VS code didn't automatically look
for the user level docker daemon that I was running. Following the prompt in the previous
paragraph I added `export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock` to my `~/.bashrc`
file. The original prompt from the user install script had my explicit UID instead of
`$(id -u)` in that line, but I modified it so it would always map to the ID of my user
across machines, since I like to reuse my dotfiles. It also makes it easier to instruct
other users on setting up their machines.

After making this change I could load devcontainers, but ran into some file permission
issues. VS code assumes that docker will be run as root, which means UID 0 in the container
will correspond to UID 0 on the host machine. Based on that it uses [namespace remapping](https://docs.docker.com/engine/security/userns-remap/) to map the `vscode` user inside the container to the host
user outside the container. Running in rootless mode works differently. UID 0 in the
container is whatever your user's UID is outside the container. This results in the
`root` user inside the container mapping to your user outside it. So if you create a file
in your workspace outside the container it will be owned by root inside it. If you create
a file inside the container it will be owned by some high unused UID outside the container.

The devcontainer spec has a number of options for changing how user mapping works.
Setting `remoteUser` or `containerUser` to root in the `devcontainer.json` would work
in the sense that I would be root in the container and have proper user level access
to files in my workspace. That wasn't ideal since the way I'd built the devcontainer there
was some customization done with the `vscode` user (pipx installations and other stuff)
that I lost if I was root. `updateRemoteUserUID` either mapped my host user to root
int the container (if set to `true`) or just didn't do any ID remapping. Within the
container as the `vscode` user I could `sudo chown -R vscode .` on the workspace directory
so that permissions all looked good inside the devcontainer. Of course this meant that
they would break if I was outside the devcontainer. That could lead to a lock out situation
if I broke the devcontainer config and was kicked out, since I wouldn't be able to edit
the `devcontainer.json` file since my host user would no longer be the owner. At the
time of this writing I don't believe there's a totally clean way to use the `vscode` user
inside a devcontainer that's running on rootless docker. My current solution is to not
do user level customization, so that running the container as root isn't a problem.
Unlike with a regular docker daemon this doesn't represent a security issue, since the
root user in the container shares the permissions of my unprivileged user outside it.

Next up was to figure out network share mounting. The normal way of creating a `CIFS`
volume does not work on rootless docker as it requires root access on the host machine.
I believe on the actual root daemon docker there are ways to allow mounting of shares from
within the container runtime itself, but in some brief testing I couldn't get them to work.
In the past I had used [gvfs](https://en.wikipedia.org/wiki/GVfs) to handle userspace
mounting of file shares, but it brings in a ton of gnome dependencies and I found it very
finicky to work with so I was hoping for a better option.

To properly test network share mounting it was time to join the host to the domain and
use a domain account for testing. While in theory I could hard code my username and
password into a credential file, in practice that's not how I'd want users to do it from
an ease of use or security perspective. This also surfaced another challenge with UID
remapping within the dev container. I'll want the network share to be associated with my
domain user and its associated user ID, which will be UID 0 in the container. Another reason
to just run as root in devcontainers if you're going to use rootless docker. After getting
the host VM joined to the domain and logging in with my domain account (unprivileged on this host)
I was ready to start testing network shares.

The approach I took was to use [Autofs](https://help.ubuntu.com/community/Autofs). All
the setup for this was done with the privileged account, then tested with the domain
joined account. First step was to install `autofs` and `cifs-utils` and enable the autofs
service. Next I created a folder under `/mnt/` for my domain user (`<user>` in the rest of this)
at `/mnt/<user>` and locked down permissions for it `chmod 700 /mnt/<user>`. I relied on
[these](https://askubuntu.com/questions/1040095/mounting-cifs-share-per-user-using-autofs)
[two](https://askubuntu.com/questions/1026316/cifs-mounts-and-kerberos-permissions-on-access-or-best-practice)
posts for the most part to figure out my config.
I added the following line to `/etc/auto.master`:

`/mnt/<user> /etc/auto.sambashares-<user> --timeout=30 --ghost` see
[here](https://learn.redhat.com/t5/Platform-Linux/Halloween-tip-of-the-day-Using-autofs-with-the-ghost-option/td-p/2326)
for the deal with the `--ghost` flag.

Next under `/etc/auto.sambashares-<user>` I added a line for each fileshare I wanted to
be able to access:

`<share_short_name> -fstype=cifs,rw,sec=krb5,uid=${UID},cruid=${UID} :<share_full_path>`

which will create a folder in `/mnt/<user>/<share_short_name>` that maps to `<share_full_path>`.

Here is where I went down a long and stupid rabbit hole. When I tried to access this share
using my domain user account I got a permission issue. Eventually I figured out my user
wasn't being issued a kerberos ticket. This led to a ton of reading about how kerberos
works, fiddling with a bunch of configs, installing and uninstalling a bunch of packages,
all to no avail. Embarassingly, eventually I realized that the issue was that I was using
an key to authenticate to this host, and you only get a kerberos ticket issued if you
do password authentication for ssh. Feeling dumb I switched to password auth and was
able to see the network share.

Having a working domain user that is able to access network shares without privilege
escalation (assuming some privileged config of autofs is done on their behalf in advance)
I was ready to get back to docker testing.

I realized I hadn't actually installed rootless docker for my domain user, so I ran the
install script and got an error that I was missing requirements and to modify `/etc/subuid`
and `/etc/subgid`. Looking at those files I could see a pattern, they look something like this:

```bash
user1:10000:65536
user2:165536:65536
user3:231072:65536
```

Each user gets an entry giving it a start UID with a very high number, and a range of
UID space that it can use within a container. The subsequent entry starts where the
previous one ends. While this got created just fine for my local users, it did not
exist for my domain user. Using my privileged account I added a record for my domain
user to `/etc/subuid` and `/etc/subgid` (they look identical) and re-ran the installer.
This time it worked fine. I added the `DOCKER_HOST` argument to my `~/.bashrc` and fired
up VS code. It didn't work. After some poking around I discovered that this was because
VS code looks in `/etc/passwd` to find your default shell, and similar to `/etc/subuid`,
domain users don't automatically get an entry there. Because of this it defaulted to
running its setup in `/bin/sh` instead of `/bin/bash` like in my other accounts, which
means it didn't read the `DOCKER_HOST` argument, which means it didn't work. Computers
are fun. I tried adding the line to `~/.profile` because apparently `/bin/sh` does read
that, but it didn't work either. Following this [stack overflow](https://serverfault.com/questions/736471/how-do-i-change-my-default-shell-on-a-domain-account)
I figured out how to add an `/etc/passwd/` entry for my domain account:
`getent passwd <user> | sudo tee -a /etc/passwd` which obviously also had to be done as
my privileged user. Once that was complete the devcontainer fired up as expected.

The last piece was to double check that I could correctly access the autofs mounted
network shares from within a container. In my `devcontainer.json` setting I added an
entry like this:

```json
 "mounts": [
	{
		"source": "/mnt/${localEnv:USER}/<share_short_name>",
		"target": "/<share_short_name>",
		"type": "bind"
	}
]
```

This worked! I also confirmed that other users on the system couldn't see any of my volumes,
images or containers. What an adventure. All in all this was about 4 days (calendar, not
hours) of effort to figure out. What an adventure.

# Cleaned up instructions

## Host configuration

Official documentation on rootless docker config can be found [here](https://docs.docker.com/engine/security/rootless/)

For further discussion of the user namespace remapping (which explains why users should be root within the devcontainer and what `/etc/subuid` and `/etc/subgid` are doing) see the official docs [here](https://docs.docker.com/engine/security/userns-remap/)


- All testing was done on an Ubuntu VM (specifically 22.04.1 LTS). As most development activity occurs within docker, most of these instructions will hopefully survive a newer Ubuntu release, and could probably even be applied to an entirely different distro if for some reason we wanted to do that. CPU, RAM and disk requirements will largely depend on the size of the team and their activity, but note that docker images tend to take up a fair bit of space, and due to (intentional) isolation of docker runtimes between users there will be no sharing of image layers. Thus 5 users each using a 2GB docker image will take up a total of 10GB of space.
- Join the machine to the domain

  ```bash
  #Setting up AD Authentication
  sudo apt install -y realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit
  #Discovery
  sudo realm discover <domain>
  #Adding to the domain (enter password when prompted)
  sudo realm join -U <privileged domain user>
  #Adding domain user to allow ssh
  realm permit -g groupname@domainname
  ```

- Install docker enginer as per [the official docker docs](https://docs.docker.com/engine/install/ubuntu/). Note, do not use the included docker package in the Ubuntu base repository.
- Make sure the system docker daemon is not running and disable it if it is: `sudo systemctl disable --now docker.service docker.socket`
- Install `autofs` and `cifs-utils` to allow users to mount network shares with their credentials.
- For each user that will be running docker on this machine, create an entry in `/etc/subuid` and `/etc/subgid` (the entry in each file should look the same)

  - each entry in each file has the format `<username>:<baseuid>:65536`. `<baseuid>` starts at 100000 for the first entry and increases by 65536 for each subsequent entry. For example, here's what `/etc/subuid` looks like on the machine where this guide was tested:

  ```bash
  admin:100000:65536
  dockertest:165536:65536
  dockertesta:231072:65536
  dockertestb:296608:65536
  <user>:362144:65536
  ```

  - Local user accounts seem to get their entries auto-generated correctly, but at least in testing, domain joined user accounts had to be manually created.

- For each user that will be running docker in this machine, create an entry in `/etc/passwd` that specifies their default shell as `bash`. Otherwise VS code will not be able to figure out the user level docker socket it should attach to.

  - `getent passwd <user> | sudo tee -a /etc/passwd`

- Create a base user folder to mount network shares for each user in `/mnt/<user>`, make that user the owner of that folder and lock down access to that user (`chown <user>` and `chmod 700 /mnt/<user>`).

- For each user that will be running docker from this machine, create a line in `/etc/auto.master` in the following format:

  ```bash
  /mnt/<user> /etc/auto.sambashares-<user> --timeout=30 –ghost
  ```

- Populate `/etc/auto.sambashares-<user>` with a line for each network share that user has to access as follows:

  ```bash
  <localsharename> -fstype=cifs,rw,sec=krb5,uid=${UID},cruid=${UID} :<full share path>
  ```

  Where `<localsharename>` is the name of the folder under `/mnt/<user>` that the share will be mounted to, and `<full share path>` is the path to the SMB file share.

## User configuration

Most configuration of the VM should have been completed by its system administrator, but there are a couple user level tasks you will have to run before you can work with docker.

### Install the rootless docker daemon

```bash
dockerd-rootless-setuptool.sh install
```

### Set an environment variable for the Docker socket

Add the following line to `~/.bashrc`: `DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock`

### Log out and back in and test

```bash
docker run hello-world
```

### Set up network shares

Attaching network shares cannot be done directly by the user. System administrators provision
network drives for each user under `/mnt/<user>`. If the network share you want is not
there, contact your system administrator with its information and they will add it.
