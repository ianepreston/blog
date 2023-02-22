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
in my home cluster with proxmox series. In this post we're going to add distributed storage
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

## Note

I ran into *lots* of problems getting this working. This post is definitely less of a guide
and more a diary of the struggles I had getting ceph working. There may be some value to
another reader if they find themselves having a similar challenge to me, but mostly this
was just my scratchpad as I worked through getting things set up.

# Initial attempt using Ansible

I was hoping that similar to my experience with postfix I'd be able to grab some ansible
roles that had been previously developed, tweak their settings a bit, and be good to go.

As you'll see, this was not the case, but here are my notes of working through the
ansible files and figuring out what they do.

## Setting up the inventory

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

## Checking the library folder

The library folder contains a script for managing proxmox VMs with the `qm` command.
That's interesting, but not relevant to what I'm trying to do with ceph so I won't worry
about it here.

## Roles

Here is going to be the bread and butter of this process. There are a number of roles
in this folder helpfully prepended with `ceph_` that I'll want to take a look at.

In terms of order of reviewing these files I'm going to look at the `site.yml` file that's
at the base of the repository to understand what order they're called in. That should make
the most sense.

### ceph_node

The first role is `ceph_node` which runs on all the nodes. There are two steps here,
the first with the name "Install ceph packages", and the second "Configure ceph network",
which I'll ignore. There's also a [handler](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html#handlers)
in this role, but it's only to restart the network after
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

### ceph_master

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
this will be a very small task. *Note from me in the future: you need the network flag.*

### ceph_mon

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

### ceph_mgr

After the monitor we create a [manager](https://docs.ceph.com/en/quincy/mgr/index.html).
The setup is basically the same as the monitor and the command it runs has even fewer
arguments than the monitor so I won't spell it out here.

### ceph_osd

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

### ceph_pool

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

### ceph_mds

After this we're doing some necessary pre-configuration for enabling ceph-fs. Specifically
the [ceph metadata server](https://docs.ceph.com/en/latest/glossary/#term-MDS). This is
another very short task that checks if the service is running and starts it if not with
a oneliner, so I won't reproduce it here.

### ceph_fs

Last one. Ceph fs, from what little I've read of it would be nice to have as it will
enable sharing storage across pods ([docs](https://rook.io/docs/rook/v1.10/Storage-Configuration/Shared-Filesystem-CephFS/filesystem-storage/)). This task has very similar structure
to the earlier ones as well so I won't write it up in detail here.

## Adding them to the playbook

Having created the roles, I now need to make sure they're done in the correct order in
my playbook. As mentioned above I can base that on the order they're listed in `site.yml`
in the base repository I've been working off.

# Troubleshoot the playbook

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
these monitors and initialize the ceph cluster with the network flag. Fun update, I can't
destroy the last monitor in a cluster. Maybe I have to reverse some of the other steps first?

The last thing I did before trying to create OSDs was create managers, so let's remove
those with `pveceph destroymgr <hostname>` on each of the nodes.

Back to my second node I try `pveceph destroymon pve2` and get the error
`can't remove last monitor`. Ok, maybe I can add the other two back now that I don't have
managers? Nope.

Ok, ceph has docs on [removing monitors from an unhealthy cluster](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/#removing-monitors-from-an-unhealthy-cluster)
I'd say that's what I have. After running these commands I don't see any running monitors,
and I'm also getting a timeout on the ceph page of proxmox and `ceph -s` is hanging from
the terminal. Since I don't have any monitors now I shouldn't have any managers either.
`pveceph mon destroy` indicates that it destroys managers as well. I can also run
`pgrep ceph-mgr` to confirm there's no manager process running.

Alright, let's try manually creating some monitors this time. Starting with my first node
I'll run `pveceph mon create` and... get an error:

```bash
root@pve1:~# pveceph mon create
Could not connect to ceph cluster despite configured monitors
```

Ok, so there must still be something in my ceph config that's pointing to the monitors,
even though I destroyed them. Maybe I'll take a step further back and remove that file
as well. After deleting the file I now get a popup in the proxmox UI on the ceph page
saying "Ceph is not initialized. You need to create an initial config once." with a
button to configure ceph. That seems like I've got everything reset back, except maybe
those initially installed packages, but that should be fine. Let's try running the
playbook again with a proper ceph network defined. Aaaand we fail to create monitors.
Let's see what's going on.

Here's the cleaned up output of the error, it's the same as from ansible just not
in json format:

```bash
root@pve1:~# pveceph mon create
unable to get monitor info from DNS SRV with service name: ceph-mon
Could not connect to ceph cluster despite configured monitors
```

Alright, I clearly haven't reset my state properly. A little more searching leads me to
`pveceph purge`. That sounds promising, let's give that a shot. I'll run it on all nodes
to be safe, and with the `--crash` and `--logs` flags to purge all the logs.
[This thread](https://forum.proxmox.com/threads/reinstall-ceph-on-proxmox-6.57691/)
has some details about purging ceph config to start clean, although the posters there
are having lots of problems, so I hope I don't have to go that far. After running the
purge command I ran my playbook and... failed at creating monitors again. However,
this time I could ssh into each host and create a monitor from the command line, same
for managers. Checking my ceph dashboard I now see all three nodes with monitors and
managers up and running. Let's leave the playbook alone for now and just try and do the
rest of this manually. On node 1 I was able to create an OSD no problem. On node 2 I
got told `device '/dev/sda' is already in use`. Following the guide I run
`ceph-volume lvm zap /dev/sda --destroy`:

```bash
root@pve2:~# ceph-volume lvm zap /dev/sda --destroy
--> Zapping: /dev/sda
--> Zapping lvm member /dev/sda. lv_path is /dev/ceph-ff288a69-40e3-4076-a422-52e100d7d302/osd-block-64f34da5-6b0c-4d20-8a60-ddc7227345ed
--> Unmounting /var/lib/ceph/osd/ceph-0
Running command: /usr/bin/umount -v /var/lib/ceph/osd/ceph-0
 stderr: umount: /var/lib/ceph/osd/ceph-0: target is busy.
-->  RuntimeError: command returned non-zero exit status: 32
```

Ok, so it looks like this is already set up as an OSD, except I don't actually see it
when I go to the ceph panel. Let's try the third node and come back to this one. That
one added just fine too, what is going on with my second node? First test, when in doubt
try turning it off and on again. After a reboot I try the commands again:

```bash
root@pve2:~# ceph-volume lvm zap /dev/sda --destroy
--> Zapping: /dev/sda
Running command: /usr/bin/dd if=/dev/zero of=/dev/sda bs=1M count=10 conv=fsync
 stderr: 10+0 records in
10+0 records out
 stderr: 10485760 bytes (10 MB, 10 MiB) copied, 0.0274736 s, 382 MB/s
--> Zapping successful for: <Raw Device: /dev/sda>
root@pve2:~# pveceph createosd /dev/sda
device '/dev/sda' is already in use
```

Ok, that's a bit of progress, I can actually run the zap, but then why can't I
create the osd? Why is it saying the device is already in use? From the disks page in
the proxmox UI I selected the disk and picked "wipe". Let's try again. And it worked.
Computers are weird.

My ceph cluster is healthy! Three monitors, three managers, three OSDs, 2.73TB of raw
disk. Let's create a storage pool:

```bash
root@pve2:~# pveceph pool create tank --add_storages
pool tank: applying size = 3
pool tank: applying application = rbd
pool tank: applying min_size = 2
pool tank: applying pg_autoscale_mode = warn
pool tank: applying pg_num = 128
```

Next up I create a metadata service on each nodes so I can run cephfs:

```bash
root@pve3:~# pveceph mds create
creating MDS directory '/var/lib/ceph/mds/ceph-pve3'
creating keys for 'mds.pve3'
setting ceph as owner for service directory
enabling service 'ceph-mds@pve3.service'
Created symlink /etc/systemd/system/ceph-mds.target.wants/ceph-mds@pve3.service -> /lib/systemd/system/ceph-mds@.service.
starting service 'ceph-mds@pve3.service'
```

This looked the same on all three nodes. Finally, some consistency!

The last piece from the playbook was to create a cephfs:

```bash
root@pve1:~# pveceph fs create --pg_num 128 --add-storage
creating data pool 'cephfs_data'...
error with 'osd pool create': mon_cmd failed -  pg_num 128 size 3 would mean 771 total pgs, which exceeds max 750 (mon_max_pg_per_osd 250 * num_in_osds 3) 
```

So close! That's what I get for just copy pasting. I guess I have to figure out how many
placement groups I should actually have.

After referencing [this post](https://ceph.io/rados/new-in-nautilus-pg-merging-and-autotuning/)
about auto scaling placement groups I have some idea where to go.

Starting with checking my current and recommended status:

```bash
root@pve1:~# ceph osd pool autoscale-status
POOL    SIZE  TARGET SIZE  RATE  RAW CAPACITY   RATIO  TARGET RATIO  EFFECTIVE RATIO  BIAS  PG_NUM  NEW PG_NUM  AUTOSCALE  BULK
.mgr   1152k                3.0         2794G  0.0000                                  1.0       1              on         False
tank      0                 3.0         2794G  0.0000                                  1.0     128          32  warn       False
```

My tank pool has 128 placement groups, with a recommended number of 32. What happens if
I change autoscale from `warn` to `on`?

After running `ceph osd pool set tank pg_autoscale_mode on` and waiting a little bit,
I do indeed now have 32 placement groups in the pool, as expected. If I do this again
I'll add `--pg_autoscale_mode on` to the arguments for my pool creation to get this
right from the beginning.

Ok, back to the file system. The default `pg_num 128` seems likely to be incorrect here,
I wonder if I can just have it auto-scale as well? Looking at the docs it doesn't seem
so. The default in my ansible playbook, which was for a similarly sized cluster used
`64`, so let's do that.

```bash
root@pve1:~# pveceph fs create --pg_num 64 --add-storage
creating data pool 'cephfs_data'...
pool cephfs_data: applying application = cephfs
pool cephfs_data: applying pg_num = 64
creating metadata pool 'cephfs_metadata'...
pool cephfs_metadata: applying pg_num = 16
configuring new CephFS 'cephfs'
Successfully create CephFS 'cephfs'
Adding 'cephfs' to storage configuration...
Waiting for an MDS to become active
Waiting for an MDS to become active
```

With that everything seems to be up! In the UI I can see my pools, and I have all green
across the board.

Let's try putting an image in there just to make sure it actually works at all.
I was able to stand up an image on my `tank` pool, boot into it, and live migrate it.
I'd say we're good!

# Get back to square one

I've done it once, let's make sure I can do it again.

## Clean up the install

As discussed in the last section I'll run `pveceph purge --crash --logs` on all three
nodes (that might be overkill but let's be safe).

```bash
root@pve1:~# pveceph purge --crash --logs
Unable to purge Ceph!

To continue:
- remove pools, this will !!DESTROY DATA!!
- remove active OSD on pve1
- remove active MDS on pve1
- remove other MONs, pve1 is not the last MON
```

Ok, I can't purge to start, I'll have to back my way out.

### remove cephfs

The list above only talks about pools, but I've got a cephfs on top of that to remove
first. The [pveceph docs](https://pve.proxmox.com/pve-docs/chapter-pveceph.html#_destroy_cephfs) have a
section on destroying a cephfs. Let's follow that.

```bash
umount /mnt/pve/cephfs
pveceph stop --service mds.cephfs # Run this on all nodes
```

That didn't seem to actually stop the MDSs, so I went into the UI and destroyed them all.
Based on the guide, after that I should be able to remove it with `pveceph fs destroy cephfs --remove-storages --remove-pools`
but I get `storage 'cephfs' is not disabled, make sure to disable and unmount the storage first`.
A little more searching gets me `ceph fs rm cephfs --yes-i-really-mean-it` which runs ok
and upon completion I don't see any entries for cephfs anymore, so I think that's good.

### remove my other pool

I think I'm going to do the rest of this through the UI. It's not the sort of thing
I need to automate, and the UI seem to be cleaner and easier. Ok, my pools are gone,
including some related to cephfs that didn't seem to clear out with the old command.
My nodes are still showing the pools as storage locations, but with a `?` by them.
I think that will go away once I purge the config for ceph, so let's not worry about it
for now.

### remove OSDs

From the UI, for each OSD in my cluster I first take it out, stop it, then destroy it.

### remove MDS

Looks like that was taken care of when I removed cephfs. No action

### remove managers and monitors

Again from the UI I `destroy` each manager, and then destroy all but one monitor.

### try purging again

Hmmm, I'm still getting told to remove pools and mons. Not sure what's up with that.
Ahh, `pveceph pool ls` tells me I still have a `.mgr` pool. I didn't realize that counted.
Ok, that's cleared out. I've still got this monitor listed under one of my nodes but with
status unknown and I can't seem to destroy it from the UI. Going into the
[ceph docs](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/) I can see
there are some docs on removing mons from an unhealthy cluster. The ghost monitor is
running on my third node so I ssh into it and I can see the monitor service is indeed
running there. I'm able to stop the service on that node with `systemctl stop ceph-mon.target`.
This still doesn't let me run purge though. If I run it I get told that my monitor isn't
the last one running, but also if I try and remove that monitor I get told it's the last
one. That's... confusing. Ok, let's go back to that third node, disable the monitor service
and reboot it the node. Still nothing. Running `ceph mon dump` on any node only shows
the monitor I know is running on my first node. Looking at `/etc/pve/ceph.conf` I only
see the one monitor. Ok, bit of googling and I'm back to
[this thread](https://forum.proxmox.com/threads/ceph-cant-remove-monitor-with-unknown-status.63613/)
which reminds me to check `/var/lib/ceph/mon` on the node with the unknown status monitor.
Sure enough, there's still a folder there and after I delete it I don't see that entry
anymore. Let's try purging again.

That seems to have worked. If I go to the ceph page in the UI I'm told that it's not configured.
I can still see the storage pools on my nodes though. I wonder if that's just in `/etc/pve/storage.cfg`
like my NFS share configs are. Yup! Ok, after deleting that I no longer see them as storage
in the UI. I think I'm good. One last thing to do is to go into each node through the UI
and wipe the SSDs.

# Retry using ansible

The manual steps worked, maybe just not having the network configured correctly when
I initially ran my playbook got me into an unstable state. After double checking my
playbook I'll try running through it one step at a time. I think the biggest issue was
the network config being missing in the initial install, which meant the monitors couldn't
talk to each other on each node and then everything spiraled from there. I've gone back
and fixed that in the playbook, and also added some syntax to enable pg autoscaling to
avoid that other issue I had during manual config.

I'm going to be a little more cautious this time and only run it with one incremental
new role uncommented at a time. I got to the monitor creation before hitting an issue.
The command completed no problem, but my node 3 monitor can't see my nodes 1 and 2 (they
can see each other). I'm thinking this is either because I didn't entirely clear out my
state, or maybe something about ansible running the monitor creation command in parallel
is breaking things. Let's just try deleting and re-adding the monitor on the third node.
Ok, I can't remove it the normal way because it thinks it's the last monitor.
`/etc/pve/ceph.conf` lists all three monitors. Running `ceph mon dump` either shows me
two monitors on my first two nodes, or just the third monitor on my last node. This is
a little different than what I had before.

Following the ceph docs for removing an unhealthy monitor doesn't help because my third
node's monitor isn't in the monmap of my healthy monitors, that's the problem:

```bash
root@pve1:~# pveceph stop --service mon.pve1
root@pve1:~# ceph-mon -i pve1 --extract-monmap /tmp/monmap
2023-02-20T16:31:41.732-0700 7f41ca2cf700 -1 wrote monmap to /tmp/monmap
root@pve1:~# monmaptool /tmp/monmap --rm pve3
monmaptool: monmap file /tmp/monmap
monmaptool: removing pve3
monmaptool: map does not contain pve3
```

Ok, back in the third node, let's clear out this monitor:

```bash
root@pve3:~# systemctl stop ceph-mon.target
root@pve3:~# systemctl disable ceph-mon.target
root@pve3:~# cd /etc/systemd/system
root@pve3:/etc/systemd/system# ls | grep ceph
ceph-mgr.target.wants
ceph-mon.target.wants
ceph.target.wants
root@pve3:/etc/systemd/system# rm -r ceph-mon.target.wants/
root@pve3:/etc/systemd/system# systemctl status ceph-mgr.target
● ceph-mgr.target - ceph target allowing to start/stop all ceph-mgr@.service instances at once
     Loaded: loaded (/lib/systemd/system/ceph-mgr.target; enabled; vendor preset: enabled)
     Active: active since Sun 2023-02-19 15:54:58 MST; 24h ago

Warning: journal has been rotated since unit was started, output may be incomplete.
root@pve3:/etc/systemd/system# systemctl stop ceph-mgr.target
root@pve3:/etc/systemd/system# systemctl disable ceph-mgr.target
Removed /etc/systemd/system/multi-user.target.wants/ceph-mgr.target.
Removed /etc/systemd/system/ceph.target.wants/ceph-mgr.target.
root@pve3:/etc/systemd/system# ls | grep ceph
ceph-mgr.target.wants
ceph.target.wants
root@pve3:/etc/systemd/system# rm -r ceph-mgr.target.wants
```

In addition to that I removed the monitor record from `/etc/pve/ceph.conf`.

After that my ceph status hung for a second, which confused me until I remembered I'd
turned off the monitor service on my first node to do that monmap dump. After turning
it back on I seem to be ok.

Now my third node is seeing my other two nodes' monitors. If I try to create a monitor
though I get told the monitor address is in use. I double checked that the unit was
completely removed and ran `systemctl daemon-reload` as well as removing everything in
`/var/lib/ceph/mon`. Maybe a reboot? Nope. Ahh! There's a line up in `/etc/pve/ceph.conf`
for `mon_host` that still has that IP listed. After deleting it I have three monitors up
and running! I think this must be a syncing issue. I don't have the energy to go back
and run this playbook from scratch to test for sure, but I'm going to add a random sleep
in front of the command like so `sleep $[ ( $RANDOM % 30 ) + 1 ]s && ` and hope that will
do it if I ever have to run this playbook again.

Back on track I added in the manager role and it worked fine. OSD creation also worked.

Pool creation failed. It looks like the conditional for checking the OSD count was
expecting `pveceph status` to return json that ansible could parse. It doesn't do that
for me so I substituted the command with `ceph osd stat | awk '{print $3}'` to get
the number of up OSDs. I don't know if that will work in weird failed states, but it
at least worked in the happy path I could test. Note that I had to change the playbook
slightly to use `shell` instead of `command` so that I could [include pipes](https://stackoverflow.com/questions/47994497/how-to-pipe-commands-using-ansible-e-g-curl-sl-host-com-sudo-bash)
and I had to cast the output of that command to an integer to let it compare to the minimum
OSD requirement. I also had to change the command to search for the pool slightly to account
for the output format of `pveceph pool ls` changing from when the playbook was written.

At this point I'm able to fully run through the playbook. Other than that issue with
monitors, that I think I've resolved, I have a fully functioning playbook for ceph
cluster provisioning.

# Conclusion

So, was automating this worth it? For actual usability, I'd have to say no. Given the
modifications I had to make to the playbook to handle the output of the status checking
commands I don't have a ton of faith that if way down the road I need to redeploy ceph
that this playbook will just work. On the other hand, trying to automate it, failing
terribly, learning to clean up that failed state, rebuild it manually, and then actually
automating it was a decent way for me to learn some things about ceph. I also picked up
a couple ansible tricks along the way. I definitely still have a ton to learn about
ceph, but I feel a little more comfortable with it than I would have if I'd just followed
the wizard in the UI. I can't imagine too many people who aren't me are going to read this
post, but maybe some of the errors I've included in it will show up in someone's future search
and they'll be able to see what I did about them, here's hoping that's useful. If not,
I learned a bunch and keeping this record helped me remember what I was doing as I worked
through this over the course of several days.