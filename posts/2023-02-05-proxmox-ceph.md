---
title: "Home Cluster Part 4 - Setup CEPH"
date: '2023-02-05'
description: "What's HA services without HA storage?"
layout: post
toc: true
categories: [configuration, proxmox, Linux, ceph]
---

# Introduction

This is the fourth post (
[part 1](2022-11-21-proxmox.md),
[part 2](2022-12-31-proxmox2.md),
[part 3](2023-01-21-proxmox3.md)
)

In my home cluster with proxmox series. In this post we're going to add distributed storage
to the cluster using [ceph](https://ceph.com/en/). As with the other posts in this series,
this is not a how-to guide from an established practitioner, but a journal I'm writing as
I try and do something new.

Ceph in many ways is overkill for what I'm doing here. It's designed to support absolutely
massive distributed storage at huge scale and throughput while maintaining data integrity.
To accomplish that it's very complicated and their [hardware recommendations](https://docs.ceph.com/en/octopus/start/hardware-recommendations/) reflect that. On the other hand, it's integrated
with proxmox and I've seen it run [on even lower spec gear](https://www.youtube.com/watch?v=Vd8GG9twjRU)
than I'm using. In this post my goal is to get a ceph cluster working that uses the 3 1TB
SSDs I have in my nodes for file sharing. I'm not going to do any performance testing or
tuning, and other than deploying an image to one just to confirm it works I probably won't
even use it in this section. The thing I actually want this storage for is to be my persistent
storage in kubernetes, backed by [rook](https://rook.io/), but that will come later once
I actually have kubernetes set up.

As with most things with computers I won't be starting from scratch. I've found a
[repository](https://github.com/peacedata0/proxmox-ansible-1) of ansible roles for setting
up a proxmox cluster that includes ceph configuration and is very similar to my overall
setup. I'll work through [vendoring](https://medium.com/plain-and-simple/dependency-vendoring-dd765be75655)
this code into my [recipes](https://github.com/ianepreston/recipes) repository through
this post.

# Setting up the inventory

The first section of the repo that I'll incorporate is the `inventory` folder. This contains
descriptions of the hosts, as well as what groups they belong to for roles. The inventory
folder in this repo also contains `group_vars` and `host_vars`, which I keep in their own
folders in my repo.

Looking at the actual inventory there are a bunch of groups created for various ceph
roles like `mds`, `mgr`, and `osd`. However, in the example case and in my case all nodes
will fulfill all roles, so this is only necessary for expansion or comprehensibility of
what tasks are doing what when a role is run. There is one differentiator for `ceph_master`,
which only targets the first node to handle tasks that are managed at the proxmox cluster
level. In my previous setup I've just had a `pve` group for the cluster and manually set
`pve1` as the host for things that take place at the cluster level. If I end up growing
my cluster a lot and want to split things out I'll have to refactor, but for now for
simplicity I'm going to stick with just using the `pve` group. Based on this I don't need
any actual changes to my inventory. Looking at `host_vars` there are host specific variables
identifying the separate NIC and IP address the nodes are using for the ceph network.
Having a separate network for ceph is a recommendation that I am not following at this
point so I don't need to worry about that. They also have a host var specifying which
storage drive should be attached to the ceph cluster. For me that's `/dev/sda` on all
of my nodes. I'll have to refactor that out if I add another node that deviates from
that, but for now I'm going to minimize the complexity in terms of number of files I have
to reference and leave that alone. Looking at the group vars under ceph there's an entry
for the pool name, and for the list of nodes. Again, both of those I can just set as
defaults for now and refactor later if I have to expand. So based on initial reading I'm
going to leave this folder alone.

# Checking the library folder

The library folder contains a script for managing proxmox VMs with the `qm` command.
That's interesting, but not relevant to what I'm trying to do with ceph so I won't worry
about it here.

# Roles

Here is going to be the bread and butter of this process. There are a number of roles
in this folder helpfully prepended with `ceph_` that I'll want to take a look at.

In terms of order of reviewing these files I'm going to look at the `site.yml` file that's
at the base of the repository to understand what order they're called in. That should make
the most sense.

## ceph_node

The first role is `ceph_node` which runs on all the nodes. There are two steps here,
the first with the name "Install ceph packages", and the second "Configure ceph network",
which I'll ignore. There's also a [handler](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html#handlers) this role, but it's only to restart the network after
configuring the second network, so I don't need that. The first task looks like this:

```yml
- name: Install ceph packages
  shell: yes | pveceph install
  args:
    creates: /etc/apt/sources.list.d/ceph.list
```

There are a few things I have not seen before here that I'd like to understand before
I blindly copy paste. The first is the `yes` command. [This post](https://www.howtogeek.com/415535/how-to-use-the-yes-command-on-linux/) explains what it is and why I'd use it. It's basically
for entering `y` into the user input of everything the command it's piped to installs.
The other thing I haven't seen before is `args`. While args appears to be a generic
[keyword](https://docs.ansible.com/ansible/latest/reference_appendices/playbooks_keywords.html#task)
its use in this case is pretty well documented in the [docs for shell](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/shell_module.html). In this case it's being used to say
that running this command will create that file, so if it exists the file doesn't need to
be run, ensuring idempotency. Pretty handy!

While I'm sure this would just work, I do want to know a bit about what I'm hitting
`y` to by running this playbook, so let's ssh into one of my nodes and manually run
the command and save the output.

```bash
root@pve1:~# ls /etc/apt/sources.list.d | grep ceph
download_proxmox_com_debian_ceph_quincy.list
```

Prior to running the command I can confirm I do not have that file present.

Running `pveceph install` prompts an `apt install` command, the `y` is to confirm that I
want to install a ton of ceph related packages. There are no other prompts so this seems
safe to run.

## ceph_master

The next role is described as creating the ceph cluster and only needs to be run on one
node. This is also a small task and it looks like this:

```yml
- name: Check ceph status
  shell: pveceph status 2>&1 | grep -v "not initialized"
  register: pveceph_status
  ignore_errors: true
  changed_when: false

- name: Create ceph network
  command: pveceph init --network 10.10.10.0/24
  when: pveceph_status.rc == 1
```

I'll have to modify the network part to match my own setup, but otherwise this looks
straightforward. Just for curiosity, let's see what the first command looks like. As a
reminder to myself, the `2>&1` redirects `stderr` to `stdout`.

```bash
root@pve1:~# pveceph status 2>&1
pveceph configuration not initialized
```

Looking at the [pveceph docs](https://pve.proxmox.com/pve-docs/pveceph.1.html) it looks
like I can just drop the `--network` argument if I'm not specifying a separate one, so
this will be a very small task.

## ceph_mon

Next up we create [monitors](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/).
This is also a simple looking role:

```yml
- name: Check for ceph-mon
  command: pgrep ceph-mon
  register: ceph_mon_status
  ignore_errors: true
  changed_when: false

- name: Create ceph-mon
  shell: pveceph createmon
  when: ceph_mon_status.rc == 1
```

`pgrep` looks for running processes, so that's how we check if the monitor is already
up and running. If it's not, we create a monitor. The only arguements for this command
are to assign an address or ID, neither of which I want to explicitly do, so I can leave this
as is.

## ceph_mgr

After the monitor we create a [manager](https://docs.ceph.com/en/quincy/mgr/index.html).
The setup is basically the same as the monitor and the command it runs has even fewer
arguments than the monitor so I won't spell it out here.

## ceph_osd

Now we have to create an [osd](https://docs.ceph.com/en/latest/man/8/ceph-osd/) which is
the first place we'll have to touch an actual disk. Having this step not be idempotent
would be *really* bad as it could lead to wiping disks. The task looks like this:

```yml
- name: Check for existing ceph_osd
  command: pgrep ceph-osd
  register: ceph_osd_pid
  changed_when: false
  ignore_errors: true

- name: Read first 5KB of ceph device to determine state
  shell: dd if={{ ceph_device }} bs=5K count=1 | sha256sum
  when: "ceph_osd_pid.rc != 0"
  register: ceph_device_first_5KB_sha256
  changed_when: false

- name: Determine if should initialize ceph_osd
  when: "ceph_osd_pid.rc != 0 and ceph_device_first_5KB_sha256.stdout == 'a11937f356a9b0ba592c82f5290bac8016cb33a3f9bc68d3490147c158ebb10d  -'"
  set_fact:
    ceph_device_initialize: true
  
- name: Initialize ceph_osd device
  when: ceph_device_initialize == True
  command: pveceph createosd {{ ceph_device }}
```

There's also a default variable for `ceph_device_initialize` that's set to `False`. It
only gets updated to true if that third step's condition is met. I'm a little confused
and worried about this role to be honest. The first step is fine, we're just checking if
the `osd` process is running. The next one is apparently making some assumption about
what the hash of the first 5KB of my disk should look like if it doesn't already have an
osd installed. I don't know how this would work and searching didn't turn anything up.
Let's test though and check what it returns on my drives:

```bash
root@pve1:~# dd if=/dev/sda bs=5K count=1 | sha256sum
1+0 records in
1+0 records out
5120 bytes (5.1 kB, 5.0 KiB) copied, 0.00509153 s, 1.0 MB/s
a11937f356a9b0ba592c82f5290bac8016cb33a3f9bc68d3490147c158ebb10d  -

root@pve2:~# dd if=/dev/sda bs=5K count=1 | sha256sum
1+0 records in
1+0 records out
5120 bytes (5.1 kB, 5.0 KiB) copied, 0.00511535 s, 1.0 MB/s
a11937f356a9b0ba592c82f5290bac8016cb33a3f9bc68d3490147c158ebb10d  -

root@pve3:~# dd if=/dev/sda bs=5K count=1 | sha256sum
1+0 records in
1+0 records out
5120 bytes (5.1 kB, 5.0 KiB) copied, 0.00503435 s, 1.0 MB/s
a11937f356a9b0ba592c82f5290bac8016cb33a3f9bc68d3490147c158ebb10d  -
```

Just to make sure I wasn't losing it, I tried it on another device that wasn't
blank and got a different hash. This is why I love the internet, there is absolutely
no way I would have figured that out on my own. I don't know how it works and that makes
me a little nervous, but at this point I'm convinced that it will work. I'll add in a
default variable for my ceph device of `/dev/sda` and should be good to go.


## ceph_pool

Now that I've got my OSDs, it's time to create a [pool](https://docs.ceph.com/en/latest/rados/operations/pools/). This role also has a defaults file, with currently just one variable to specify
the minimum number of nodes that must be up for pool creation (set to 3 which works for me).
I'll have to add in another default to mine for the pool name, as the original repo sets
that in group vars. Beyond that let's focus on the task:

```yml
- name: Check ceph status
  command: pveceph status
  register: pveceph_status
  ignore_errors: true
  changed_when: false

- name: Check ceph pools
  shell: pveceph pool ls | grep -e "^{{ ceph_pool }} "
  register: ceph_pool_status
  changed_when: false
  ignore_errors: true

- name: Create ceph pool
  when: ceph_pool_status.rc > 0 and (pveceph_status.stdout | from_json).osdmap.osdmap.num_up_osds >= minimum_num_osds_for_pool
  command: pveceph pool create {{ ceph_pool }}

- name: Check ceph-vm storage
  command: pvesm list ceph-vm
  changed_when: false
  ignore_errors: true
  register: ceph_vm_status

- name: Create ceph VM storage (ceph-vm)
  when: ceph_vm_status.rc > 0
  command: pvesm add rbd ceph-vm -nodes {{ ceph_nodes }} -pool {{ ceph_pool }} -content images

- name: Check ceph-ct storage
  command: pvesm list ceph-ct
  changed_when: false
  ignore_errors: true
  register: ceph_ct_status

- name: Create ceph container storage (ceph-ct)
  when: ceph_ct_status.rc > 0
  command: pvesm add rbd ceph-ct -nodes {{ ceph_nodes }} -pool {{ ceph_pool }} -content rootdir
```

The first step pulls up a detailed description of the ceph pool status. In the third step
we'll parse it to check that we have the minimum number of OSDs up. The next one is
pretty straightforward, make sure the pool we want to create doesn't already exist.
Next, assuming we have at least the minimum number of OSDs and our pool hasn't been created,
create it. This one is using all the defaults of the command since we don't pass any arguments.
Briefly, they are:

* not to configure VM and CT storage for the pool (that appears to happen later)
* set the application as [rbd](https://docs.ceph.com/en/quincy/rbd/index.html)
    (we will configure ceph fs later on).
* Some other stuff about scaling and erasure coding that I don't understand and hopefully
    won't need for now. Full docs [here](https://pve.proxmox.com/pve-docs/pveceph.1.html),
    search for `pveceph pool create <name> [OPTIONS]`

The next four parts configure proxmox to use ceph as a storage location for VMs and
containers. I actually don't want to do that, my VMs will live on my nvme drives, but
it won't hurt to have as an option I guess, and at least I can test if I can do stuff
on the pool with this enabled so I'll leave it but not spend much time working out
how it works. I will have to add a variable for `ceph_nodes` to my defaults that maps
to a comma separated list of my nodes.

## ceph_mds

After this we're doing some necessary pre-configuration for enabling ceph-fs. Specifically
the [ceph metadata server](https://docs.ceph.com/en/latest/glossary/#term-MDS). This is
another very short task that checks if the service is running and starts it if not with
a oneliner, so I won't reproduce it here.

## ceph_fs

Last one. Ceph fs, from what little I've read of it would be nice to have as it will
enable sharing storage across pods ([docs](https://rook.io/docs/rook/v1.10/Storage-Configuration/Shared-Filesystem-CephFS/filesystem-storage/)). This task has very similar structure
to the earlier ones as well so I won't write it up in detail here.

# Adding them to the playbook

Having created the roles, I now need to make sure they're done in the correct order in
my playbook. As mentioned above I can base that on the order they're listed in `site.yml`
in the base repository I've been working off.

# Run the playbook

Moment of truth, will it work or will I get errors?

```json
{"changed": true, "cmd": ["pveceph", "createosd", "/dev/sda"], "delta": "0:00:00.421412", "end": "2023-02-05 20:09:49.235881", "msg": "non-zero return code", "rc": 2, "start": "2023-02-05 20:09:48.814469", "stderr": "binary not installed: /usr/sbin/ceph-volume", "stderr_lines": ["binary not installed: /usr/sbin/ceph-volume"], "stdout": "", "stdout_lines": []}
```

Of course it's not that easy. I made it to the `ceph_osd` role but then hit this failure.
Let's compare the steps I've put into my playbook with the [proxmox docs](https://pve.proxmox.com/pve-docs/chapter-pveceph.html) and see if I missed anything.

It looks like the manual tasks match what I did in the playbook, so that's not it. Next
I'll search for the error message I got from ansible (probably should have done that first).
I found a bug report stating that `ceph-volume` is only recommended by `ceph-osd`, so depending
on apt settings it may not get installed. Weird, but easy to fix. In the `ceph_node` role
I add the following:

```yml

- name: Install extra ceph packages
  apt:
    name: ceph-volume
```

Ok, that got me a bit farther, but now I have new errors. First off, let's manually check
what state my system is in before I assess anything else. Looking at the ceph dashboard
in proxmox I have 1 OSD showing in and up, -1 (?) showing out and up, and 1 showing out
and down. That's interesting. Running `pgrep ceph-osd` on each node I get a PID for my
second node, but not for the other two. Fun. Let's just try manually zapping the SSD on
the other two hosts and see what happens. First I run `ceph-volume lvm zap /dev/sda --destroy`
to wipe the SSD (just to be safe), and then I run `pveceph createosd /dev/sda`. Let's find
out how that goes.

```bash
root@pve1:~# pveceph createosd /dev/sda
create OSD on /dev/sda (bluestore)
wiping block device /dev/sda
200+0 records in
200+0 records out
209715200 bytes (210 MB, 200 MiB) copied, 0.520585 s, 403 MB/s
Running command: /bin/ceph-authtool --gen-print-key
Running command: /bin/ceph --cluster ceph --name client.bootstrap-osd --keyring /var/lib/ceph/bootstrap-osd/ceph.keyring -i - osd new ab6b5e33-e5ca-40b6-a94e-40d3ce61283d
 stderr: 2023-02-06T16:01:03.421-0700 7f32c24e1700 -1 auth: unable to find a keyring on /etc/pve/priv/ceph.client.bootstrap-osd.keyring: (2) No such file or directory
 stderr: 2023-02-06T16:01:03.421-0700 7f32c24e1700 -1 AuthRegistry(0x7f32bc060800) no keyring found at /etc/pve/priv/ceph.client.bootstrap-osd.keyring, disabling cephx
 stderr: 2023-02-06T16:01:03.425-0700 7f32bb7fe700 -1 monclient(hunting): handle_auth_bad_method server allowed_methods [2] but i only support [2]
 stderr: 2023-02-06T16:01:03.425-0700 7f32c0a7e700 -1 monclient(hunting): handle_auth_bad_method server allowed_methods [2] but i only support [2]
 stderr: [errno 13] RADOS permission denied (error connecting to the cluster)
-->  RuntimeError: Unable to create a new OSD id
command 'ceph-volume lvm create --cluster-fsid 6d4cf20c-f09d-4edf-ae78-0038b57f9709 --data /dev/sda' failed: exit code 1
```

Ok so I'm getting an error connecting to the cluster, why would that be? Checking
the ceph status from the proxmox interface it appears that the monitor is skipping between
running on my first and third nodes, but not my second (which is where I was able to install
the OSD). Now I'm really confused and wondering if maybe I should have just done this whole
thing manually through the GUI. But what would I learn that way? Ok, one thing I didn't
do was create a separate network for ceph. Maybe I should have done that. Let's destroy
these monitors and initialize the ceph cluster with the network flag.