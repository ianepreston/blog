---
title: "Notes on Kubernetes the hard way"
date: '2023-02-24'
description: "I may have bit off a bit more than I could chew"
layout: post
toc: true
categories: [kubernetes, proxmox, Linux]
---

# Introduction

In this post I'll be recording notes related to working through
[kubernetes the hard way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
by Kelsey Hightower. I've gone through a few kubernetes tutorials before, and messed
around with [minikube](https://minikube.sigs.k8s.io/docs/) a bit, but that's it.
Before I try and get a "proper" k8s cluster going on my proxmox setup I'm going to try
and work through this guide in the hope that it will improve my understanding of the setup.

# Provisioning compute

All the terraform code for the provisioning can be found [here](https://github.com/ianepreston/scratch/tree/main/k8s-the-hard-way/pve-terraform).

Almost immediately I'm deviating from the guide because it expects me to deploy things
in google cloud, and instead I'm going to do it on my local network. I don't expect this
to cause me a ton of problems, except I won't have access to an external cloud load balancer,
so I'll have to figure something else out there. I'll cross that bridge when I get to it.

Additionally, I also can't provision the VMs the guide recommends using the gcs specific
commands, instead I'll use terraform to provision VMs from the templates I set up in
[an earlier post](2023-01-21-proxmox3.md).

## Sidebar to load in secrets

Terraform needs credentials to control my proxmox cluster, and I clearly don't want to
have those in git. In my earlier post I mentioned that I'd try using vault or bitwarden
to manage secrets at some point. I'm going to save vault for now, but I have added
the [bitwarden cli](https://bitwarden.com/help/cli/) to my devcontainer, so I should
be able to use it to securely retrieve credentials into a project. I created a secure
note in bitwarden labeled `pve_terraform_cred`, now to load that into my workspace.

This actually turned out to be pretty straightforward, which was a nice surprise:

```bash
if [ ! -f pve_creds.env ]; then
    echo "Credentials file doesn't already exist, loading from Bitwarden."
    echo "Logging into bitwarden"
    bw login
    echo "Getting the terraform creds"
    bw get notes pve_terraform_cred > pve_creds.env
fi
```

Now when I start working in terraform I just have to run `source pve_creds.env` in my
terminal to have the environment variables for my username and password available.
I spent a bit of time trying to get the script itself to set the environment variables,
but child processes can't modify the environment of their parents so I'm stuck there.

## Basic setup

I covered this in the templates post, but briefly let's go over setting up the provider
and a connection to my cluster. In my `main.tf` file I have the following code:

```tf
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.11"
    }
  }
}
provider "proxmox" {
  pm_tls_insecure = true
  pm_api_url      = "https://pve1.local.ipreston.net:8006/api2/json"
}
```

And that's it for setting up the connection. I have environment variables set by
my script above with the username and password to my cluster so I don't need to provide
anything in the code. A quick `terraform init` followed by `terraform plan` shows that
I'm all set up.

## Provision VMs

To follow the guide I will need to create a total of 6 VMs, 3 each of controllers and
workers. The configuration of all of these nodes should be largely identical, with
the exception of hostname, IP address, and which proxmox node they're loaded on. The
most straightforward way to do this in terraform would be to just set up one VM, and then
copy-paste its config 5 more times with slight modifications. I could do a slightly
fancier version with [for each loops](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each),
but that will still have a lot of common config mixed in with the parts that are looping
and will be tricky to read and update. It's a bit overkill for something like this,
but the point here is learning so I'm going to create a [module](https://developer.hashicorp.com/terraform/tutorials/modules/module-create)
that hard codes all the common aspects of the VMs I'm going to create and only leaves
the parts that will change across nodes and controlllers/workers as variables.

### Create a module

In the terraform folder I'll make a `modules/ubuntu-vm` subdirectory and in that I'll place
two files. First we have `variables.tf`:

```tf
variable "node" {
  description = "Proxmox node number to deploy to"
  type        = number
}

variable "type" {
  description = "A controller or worker node"
  type        = string
}

variable "ip" {
  description = "The static IP for the VM"
  type        = string
}
```

This is just defining the variables that I'll need to pass into this module to create
a resource. As described above, I want everything else about these nodes to be the same,
so this is all I need for variables.

Then I have a `main.tf`:

```tf
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.11"
    }
  }
}

resource "proxmox_vm_qemu" "ubuntu-vm" {
  name        = "ubuntu-${var.type}-${var.node}"
  target_node = "pve${var.node}"
  onboot      = true
  oncreate    = true
  clone       = "ubuntujammytemplate"
  full_clone  = true
  agent       = 1
  os_type     = "cloud-init"
  cores       = 4
  cpu         = "host"
  memory      = 8192
  bootdisk    = "scsi0"
  disk {
    slot     = 0
    size     = "100G"
    type     = "scsi"
    storage  = "local-zfs"
    iothread = 1
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }
  ipconfig0 = "ip=${var.ip}/24,gw=192.168.85.1"
}
```

Having to put the required provider up here was a little confusing at first, since I had
it defined in the base terraform module, but after some errors and troubleshooting I learned
that I have to specify the required provider in every module that uses it. Note that I don't
have the `provider` block that explicitly points to the actual proxmox instance I want to
apply this to, that only lives in the base module. The rest of this block is a standard
[terraform proxmox VM](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs/resources/vm_qemu)
resource where I've hard coded in all the parameters I want to be consistent across nodes,
and plugged in variables for the parts that are going to change.

### Fun with loops

The other tricky part of this is that I would really like to do nested for each loops,
which I guess isn't a native concept in terraform. In python to create the map of values
that I want I'd do something like:

```python
vms = [
    {
        "nodetype": nodetype,
        "pvenode": i + 1,
        "vm_ip": f"192.168.85.{70 + base_octet + i}"
    }
    for nodetype, base_octet in [("controller", 0), ("worker", 3)]
    for i in range(3)
]
```

I can't nest a for each in terraform, so I have to do some nested for loops in variables
to create a map that I can then use for each on. [This blog](https://faultbucket.ca/2020/09/terraform-nested-for_each-example/)
has basically the same issue so I should be able to follow its logic to produce what I
want. After some fiddling around I get the following:

```tf
locals {
  nodetypes = {
    "controller" = 0
    "worker"     = 3
  }
  vm_attrs_list = flatten([
    for nodetype, baseoctet in local.nodetypes : [
      for i in range(3) : {
        name = "${nodetype}${i}"
        node = "${i + 1}",
        type = "${nodetype}",
        ip   = "192.168.85.${70 + baseoctet + i}"
      }
    ]
  ])
  vm_attrs_map = {
    for obj in local.vm_attrs_list : "${obj.name}" => obj
  }

}
```

Which is certainly a lot more verbose than python, but whatever. I can check it out
before trying to apply it to a resource by using `terraform console`:

```bash
❯ terraform console
> local.vm_attrs_map
{
  "controller0" = {
    "ip" = "192.168.85.70"
    "name" = "controller0"
    "node" = 1
    "type" = "controller"
  }
  "controller1" = {
    "ip" = "192.168.85.71"
    "name" = "controller1"
    "node" = 2
    "type" = "controller"
  }
  "controller2" = {
    "ip" = "192.168.85.72"
    "name" = "controller2"
    "node" = 3
    "type" = "controller"
  }
  "worker0" = {
    "ip" = "192.168.85.73"
    "name" = "worker0"
    "node" = 1
    "type" = "worker"
  }
  "worker1" = {
    "ip" = "192.168.85.74"
    "name" = "worker1"
    "node" = 2
    "type" = "worker"
  }
  "worker2" = {
    "ip" = "192.168.85.75"
    "name" = "worker2"
    "node" = 3
    "type" = "worker"
  }
}
```

## Put it all together

Now that I've got my module created and my map to loop over I can finish up in `main.tf`
in the root of this project:

```tf
module "ubuntu_vm" {
  source   = "./modules/ubuntu-vm"
  for_each = local.vm_attrs_map
  node     = each.value.node
  type     = each.value.type
  ip       = each.value.ip
}
```

Nice and easy! I run `terraform init` again so that the module I created is loaded,
then `terraform plan` to make sure I'm actually getting the 6 nodes I expect. Everything
looks good so I run `terraform apply`... and wait an hour and a half for it to not actually
deploy any nodes. When I initially tested terraform back when I was doing templates I did
notice that it took a lot longer to deploy via terraform than via the menu, but that was
minutes, not hours. Time to figure out what's going on here.

As a fun aside to remember for later, as part of troubleshooting I tried updating
the proxmox provider from the `2.9.11` version I was using to the `2.9.13` release
and it just straight up doesn't work. Everything installs ok but then I get:

```bash
❯ terraform plan
╷
│ Error: Plugin did not respond
│ 
│   with provider["registry.terraform.io/telmate/proxmox"],
│   on main.tf line 9, in provider "proxmox":
│    9: provider "proxmox" {
│ 
│ The plugin encountered an error, and failed to respond to the plugin.(*GRPCProvider).ConfigureProvider call. The plugin
│ logs may contain more details.
╵
```

When I revert back to the old release I can at least run `terraform plan`. There are quite
a few threads about how the proxmox provider for terraform is kind of buggy and I'm starting
to wonder if ansible would be a better way to go. I like the ability of terraform to tear
down infrastructure with `terraform destroy` but I'm not sure it's worth all this other
hassle. I'll keep messing with it for a bit though.

I found an
[open issue](https://github.com/Telmate/terraform-provider-proxmox/issues/325) on the
proxmox terraform provider about slow provisioning. There's also
[this one](https://github.com/Telmate/terraform-provider-proxmox/issues/705) about issues
deploying multiple VMs. Both are still open but there were
some suggested config changes, along with a recommendation to run in debug. Let's try
that with `TF_LOG=DEBUG terraform apply --auto-approve`. This dumped a giant stream of
output, most of which I will not reproduce. One thing that caught my eye was that it
couldn't find the template VM I wanted to use. Looking back at my code I realized that
I had missed the dashes in the template name. That's definitely on me, although I'm going
to put some blame on the provider for just hanging forever instead of returning an error.

After fixing the template the playbook applied and I had 6 VMs up and running, two on each
node. It took a couple minutes to apply, but that's not bad at all. Problem solved?

Almost. The newly deployed VMs are up and running, and I can ssh into them at their IPs,
but they don't have qemu guest agents running so I can't see their IPs from the proxmox
UI, or load up a terminal session from there. This isn't the end of the world, but I'd
like to fix it if I can. I think the problem is that I had `agent` turned off in the proxmox
config as part of troubleshooting the slow deploy. Let's see if I can fix that. This will
also give me a chance to confirm that `terraform destroy` works. The destroy worked no
problem. Setting `agent = 1` back in the template config worked fine in terms of creating
the VM (no slowdown in deploy), but I still couldn't load them from the proxmox UI. I created a
manual clone of the same template to see if I could figure out the issue there. This one
did show me the configured IP, but still wouldn't let me open a console. After some more
troubleshooting I realized this was because
[some changes](https://github.com/ianepreston/recipes/commit/a98994320b20d00e4b702aaf7aa9b3357039a07b#diff-8ea9f6ece084ec63cd3ec7c27a9cc2b4d1638be05824823990187a97dad99767)
I'd made to my proxmox ssh host
keys were blocking me from bringing up terminal sessions on any hosts other than the one
I was connecting to the UI through. Again, that's totally my bad, although I could have
gone for some better error messages.

# Generating config

All the ansible playbooks and configs for the sections below can be found
[here](https://github.com/ianepreston/scratch/tree/main/k8s-the-hard-way/ansible).

## Provisioning a CA and Generating TLS certificates

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/01_ca_certs.yml)

On to [chapter 4](https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md) in the guide!

I have to do some minor modification of the scripts outlined in the doc since I'm not
using GCP. I think for these future configs I'm going to use ansible, since that's how
I'd like to actually manage hosts in the future.

The first big headache I ran into was getting `cfssl` installed to generate the certs.
It didn't have a `.deb` available that I could find so I had to install `go` and then
install the package there, as well as figuring out how to make the path to the binary
it installed available to my user (learned a couple things about `GOPATH` in the process).

Other than that creating all the keys and copying them onto the hosts was pretty straightforward
ansible. I'll have to wait until later to see if anything broke, but for now it seems good.

## Generating Kubernetes configuration files for authentication

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/02_kube_config.yml)

On to the next thing! This section uses `kubectl`, which I fortunately already have
available in my devcontainer, so no config required there. I'll keep going with my pattern
of using ansible to manage the scripting. No issues with any of these steps, at least
not at this point. I might have to come back to some of it for troubleshooting.

## Generating the data encryption config and key

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/03_encryption.yml)

Same as the above. I did a slightly different workflow for the ansible playbook. Since
this called for generating a random number as part of the config, rather than doing
something fancy like registering the output of a command to generate the random number
and then inserting that into a template I just wrapped the whole thing in a shell command.

# Bootstrap the etcd cluster

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/04_bootstrap_etcd.yml)

On to [chapter 7](https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/07-bootstrapping-etcd.md)
Now we're getting into interesting stuff where I'm actually starting services on the nodes.
The instructions for this part are fairly imperative so I'll actually have to do some
modification to make them work properly with ansible, for instance using
[get_url](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/get_url_module.html)
instead of invoking `wget` to grab the `etcd` binary. Actually upon further reading I
can just use the [unarchive](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/unarchive_module.html)
module to download and extract the archive, neat!

This all seemed to be going well until I actually had to start the etcd service and hit
an error:

```bash
ipreston@ubuntu-controller-1:~$ systemctl status etcd.service
● etcd.service - etcd
     Loaded: loaded (/etc/systemd/system/etcd.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Sat 2023-03-04 23:55:47 UTC; 3s ago
       Docs: https://github.com/coreos
    Process: 13038 ExecStart=/usr/local/bin/etcd \ (code=exited, status=203/EXEC)
   Main PID: 13038 (code=exited, status=203/EXEC)
        CPU: 1ms
```

Ok, looks like when I copied the `etcd` binaries into `/usr/local/bin` they lost their
execute permission. Adding `mode: '0700'` to the copy task in ansible seems to fix that,
but now I have a new failure:

```bash
ipreston@ubuntu-controller-1:~$ systemctl status etcd.service
● etcd.service - etcd
     Loaded: loaded (/etc/systemd/system/etcd.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Sun 2023-03-05 00:00:09 UTC; 3s ago
       Docs: https://github.com/coreos
    Process: 13571 ExecStart=/usr/local/bin/etcd \ (code=exited, status=1/FAILURE)
   Main PID: 13571 (code=exited, status=1/FAILURE)
        CPU: 13ms
```

Running `journalctl -xeu etcd.service` I think the pertinent line is:

```bash
Mar 05 00:02:26 ubuntu-controller-1 etcd[13841]: error verifying flags, '\' is not a valid flag. See 'etcd --help'.
```

I'm able to run the `etcd` binary manually, so my best guess is something in my service
definition is wrong.

Two problems came up after looking at the output of the template. First I had to change
my variable to get the host IP address from `{{ ansible_default_ipv4 }}` to
`{{ ansible_default_ipv4.address }}` to just get the IP address instead of a big dictionary
of everything about the network connection. Next I think the code I copied from the guide
had `\\` after every line break to escape the `\` character because it was being piped
through `tee` in the example. Since I'm not doing that I swapped to just a `\`.

This seems to have cleaned up the service definition, but I'm still having a failure.

```bash
ipreston@ubuntu-controller-1:~$ systemctl status etcd.service
● etcd.service - etcd
     Loaded: loaded (/etc/systemd/system/etcd.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Sun 2023-03-05 00:14:59 UTC; 1s ago
       Docs: https://github.com/coreos
    Process: 15563 ExecStart=/usr/local/bin/etcd --name ubuntu-controller-1 --cert-file=/etc/etcd/kuber>
   Main PID: 15563 (code=exited, status=1/FAILURE)
        CPU: 15ms

Mar 05 00:14:59 ubuntu-controller-1 systemd[1]: etcd.service: Failed with result 'exit-code'.
Mar 05 00:14:59 ubuntu-controller-1 systemd[1]: Failed to start etcd.
```

Looking at journalctl again it looks like my error is `Mar 05 00:15:09 ubuntu-controller-1 etcd[15585]: couldn't find local name "ubuntu-controller-1" in the initial cluster configuration`. Right, that's because I didn't
update that part of the template from the hostnames used in the guide to the hostnames I
gave my controllers. One more try.

Alright, now the service is started. Running the confirmation command from the guide
I get an output that looks good:

```bash
ipreston@ubuntu-controller-1:~$ sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \cd-v3.4.15-linux-amd64$
  --cacert=/etc/etcd/ca.pem \~/etcd/etcd-v3.4.15-linux-amd64$
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
7dceec040adbf023, started, ubuntu-controller-2, https://192.168.85.71:2380, , false
ab94230b177e1d5c, started, ubuntu-controller-1, https://192.168.85.70:2380, https://192.168.85.70:2379, false
e88d02db26fab5bc, started, ubuntu-controller-3, https://192.168.85.72:2380, https://192.168.85.72:2379, false
```

I'm getting some concerning errors in the service status though:

```bash
ipreston@ubuntu-controller-1:~$ systemctl status etcd.service
● etcd.service - etcd
     Loaded: loaded (/etc/systemd/system/etcd.service; enabled; vendor preset: enabled)
     Active: active (running) since Sun 2023-03-05 00:18:35 UTC; 3min 29s ago
       Docs: https://github.com/coreos
   Main PID: 16361 (etcd)
      Tasks: 14 (limit: 9492)
     Memory: 37.6M
        CPU: 33.018s
     CGroup: /system.slice/etcd.service
             └─16361 /usr/local/bin/etcd --name ubuntu-controller-1 --cert-file=/etc/etcd/kubernetes.pem --key-file=/etc/etcd/kubernetes-key.pem --peer-cert-file=/etc/etcd/kubernetes.pem --peer-key-file=/etc/etcd/kubernetes-key.pem --trusted-ca-file=/>
Mar 05 00:22:04 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37770" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:04 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37780" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37790" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37796" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: health check for peer 7dceec040adbf023 could not connect: x509: certificate is valid for 192.168.85.70, 192.168.86.71, 192.168.85.72, 127.0.0.1, not 192.168.85.71
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: health check for peer 7dceec040adbf023 could not connect: x509: certificate is valid for 192.168.85.70, 192.168.86.71, 192.168.85.72, 127.0.0.1, not 192.168.85.71
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37806" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37818" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37828" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
Mar 05 00:22:05 ubuntu-controller-1 etcd[16361]: rejected connection from "192.168.85.71:37832" (error "tls: \"192.168.85.71\" does not match any of DNSNames [\"kubernetes\" \"kubernetes.default\" \"kubernetes.default.svc\" \"kubernetes.default.svc.cl>
```

Right, right, that's because I had a typo in the cert generation where I put `192.168.86.71`
instead of `192.168.85.71`. Ok, fine. Fix that and try again.

Looks like it works! The service is up and running, the status is not beset with errors
about not being able to talk. I think I'm good!

# Bootstrap the kubernetes control plane

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/05_bootstrap_control_plane.yml)

A lot of the activity in this section is similar to bootstrapping the etcd cluster from
an ansible perspective. Download some files, copy some others over into various locations,
start up some systemd units and off you go. I had very few issues getting this initially
set up, except that I realized I'd missed copying over one config file in the CA certs
section so I had to go back and update that playbook to fix that issue.

When it came time to verify the cluster status though I ran into an issue:

```bash
ipreston@ubuntu-controller-1:~$ sudo kubectl cluster-info --kubeconfig admin.kubeconfig

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?
```

So now we're in troubleshooting mode. First up, let's check the status of the services
I just started:

```bash
ipreston@ubuntu-controller-1:~$ systemctl status kube-apiserver
● kube-apiserver.service - Kubernetes API Server
     Loaded: loaded (/etc/systemd/system/kube-apiserver.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Sun 2023-03-12 22:17:56 UTC; 2s ago
       Docs: https://github.com/kubernetes/kubernetes
    Process: 19077 ExecStart=/usr/local/bin/kube-apiserver \ (code=exited, status=1/FAILURE)
   Main PID: 19077 (code=exited, status=1/FAILURE)
        CPU: 83ms
```

ok, not off to a great start.

Back to my old friend `journalctl -xeu kube-apiserver`:

```bash
Mar 12 22:19:04 ubuntu-controller-1 kube-apiserver[19370]: Error: "kube-apiserver" does not take any arguments, got ["\\"]
```

Oh right, this is that problem with templates again compared to how the GitHub page
wants me to `cat` this stuff in.

```bash
ipreston@ubuntu-controller-1:~$ sudo kubectl cluster-info --kubeconfig admin.kubeconfig
Kubernetes control plane is running at https://127.0.0.1:6443

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
```

Alright! At least that was an easy fix. Should have remembered it from last time, but oh
well.

This section has some instructions for setting up a proxy to handle health checks from
the load balancer, but I don't have a load balancer at this point, so I'm going to skip
it. I'll have to figure out how to set all that up when I'm doing a proper cluster, but
this is just for learning so I'll skip it.

## RBAC for the kubelet authorization

These commands I only have to run on one node, and I'm not sure how to easily make
them idempotent with ansible. They're making changes on my cluster, not creating files
(at least that I know of), so I don't know how to tell ansible not to re-run the commands.
In theory running them multiple times shouldn't really matter, so I'll just do it
manually anyway.

## Front end load balancer

Again, I don't actually have a load balancer (maybe that will be what I do in my next
post). So I'll skip this part.

# Bootstrapping the kubernetes worker nodes

[Ansible playbook](https://github.com/ianepreston/scratch/blob/main/k8s-the-hard-way/ansible/06_bootstrap_workers.yml)

This is the last major step in having a working cluster as far as I can tell.
The first step is installing some system dependencies, which is no problem. The next
step is making sure swap is off. I started looking into idempotent ways to ensure this
wasn't turned on, then decided to just check if it was in my VMs to begin with. Turns out
I didn't set them up with swap to begin with so I can just skip that part.

Next I've got a bunch of binaries to install. Some of them are gzipped tar files and
some are straight binaries. In both cases I can refer back to what I did for setting
up the controllers and etcd to build the playbook. All of this actually went quite smoothly.
At the end of running the playbook it looks like I have three worker nodes in my cluster!

```bash
ipreston@ubuntu-controller-1:~$ sudo kubectl get nodes --kubeconfig admin.kubeconfig
NAME              STATUS   ROLES    AGE     VERSION
ubuntu-worker-1   Ready    <none>   2m35s   v1.21.0
ubuntu-worker-2   Ready    <none>   2m35s   v1.21.0
ubuntu-worker-3   Ready    <none>   2m35s   v1.21.0
```

# Configuring kubectl for remote access

Let's try this on my devcontainer. Again, I should be pointing at a load balancer,
but I don't have one, so I'm not. From the `workspace_ansible` folder within my devcontainer
that has all my credentials saved I run the commands in [the guide](https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/10-configuring-kubectl.md)

After setting the context I run `kubectl version` and get:

```bash
❯ kubectl version --output=json
{
  "clientVersion": {
    "major": "1",
    "minor": "26",
    "gitVersion": "v1.26.1",
    "gitCommit": "8f94681cd294aa8cfd3407b8191f6c70214973a4",
    "gitTreeState": "clean",
    "buildDate": "2023-01-18T15:58:16Z",
    "goVersion": "go1.19.5",
    "compiler": "gc",
    "platform": "linux/amd64"
  },
  "kustomizeVersion": "v4.5.7",
  "serverVersion": {
    "major": "1",
    "minor": "21",
    "gitVersion": "v1.21.0",
    "gitCommit": "cb303e613a121a29364f75cc67d3d580833a7479",
    "gitTreeState": "clean",
    "buildDate": "2021-04-08T16:25:06Z",
    "goVersion": "go1.16.1",
    "compiler": "gc",
    "platform": "linux/amd64"
  }
}
WARNING: version difference between client (1.26) and server (1.21) exceeds the supported minor version skew of +/-1
```

Most of this looks fine, the version skew is because I'm using old kubernetes based
on the static guide on my server.

`kubectl get nodes` returns my three worker nodes, so I'm set!

# Provisioning pod network routes

This appears to only matter if I'm in the cloud. I'm going to skip it.

# Deploying the DNS cluster add-on

I'm sure there are more DevOpsy ways to do these kubectl commands, with or without ansible,
but I don't feel like learning them as part of this exercise, so I'm just going to run
these commands from my devcontainer and see how it goes:

```bash
❯ kubectl apply -f https://storage.googleapis.com/kubernetes-the-hard-way/coredns-1.8.yaml
serviceaccount/coredns created
clusterrole.rbac.authorization.k8s.io/system:coredns created
clusterrolebinding.rbac.authorization.k8s.io/system:coredns created
configmap/coredns created
deployment.apps/coredns created
The Service "kube-dns" is invalid: spec.clusterIPs: Invalid value: []string{"10.32.0.10"}: failed to allocated ip:10.32.0.10 with error:provided IP is not in the valid range. The range of valid IPs is 192.168.85.0/24
```

Right out the gate I get an error. Nice. I guess I'll download and then modify this file.
After downloading and modifying the IP to point to my cluster it seems to work:

```bash
❯ kubectl apply -f coredns-1.8.yaml 
serviceaccount/coredns unchanged
clusterrole.rbac.authorization.k8s.io/system:coredns unchanged
clusterrolebinding.rbac.authorization.k8s.io/system:coredns unchanged
configmap/coredns unchanged
deployment.apps/coredns unchanged
service/kube-dns created
```

Except maybe it didn't?

```bash
❯ kubectl get pods -l k8s-app=kube-dns -n kube-system
No resources found in kube-system namespace.
```

Jumping ahead let's try and deploy the `busybox` pod just to see if I can get anything
running:

```bash
❯ kubectl run busybox --image=busybox:1.28 --command -- sleep 3600
Error from server (Forbidden): pods "busybox" is forbidden: error looking up service account default/default: serviceaccount "default" not found
```

Ok, do I have any service accounts?

```bash
❯ kubectl get serviceAccounts
No resources found in default namespace
```

Guess not. What step did I miss? From [this post](https://stackoverflow.com/questions/33528398/why-dont-i-have-a-default-serviceaccount-on-kubernetes) I should get this from the
`kube-controller-manager` binary. Looking back I can see that I did at least attemp
to install that program and set up a service for it. Let's see check its status on
one of my controller nodes:

```bash
ipreston@ubuntu-controller-1:~$ systemctl status kube-controller-manager
● kube-controller-manager.service - Kubernetes Controller Manager
     Loaded: loaded (/etc/systemd/system/kube-controller-manager.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Fri 2023-03-17 17:20:35 UTC; 127ms ago
       Docs: https://github.com/kubernetes/kubernetes
    Process: 589315 ExecStart=/usr/local/bin/kube-controller-manager --bind-address=0.0.0.0 --cluster-cidr=192.168.85.0>
   Main PID: 589315 (code=exited, status=1/FAILURE)
        CPU: 651ms
```

Cool, that would explain it. Looking through `journalctl -xeu kube-controller-manager`
I see `/var/lib/kubernetes/kube-controller-manager.kubeconfig: no such file or directory`.
Let's see where I was supposed to generate that and figure out what went wrong. Going
back into my code I see I generated the file but didn't copy it into `/var/lib/kubernetes`
in my control plane playbook when I copied the rest of the configs in. Let's try again.

Ok, after re-running the playbook with that file added the service is up and running.

Let's try that command again.

```bash
❯ kubectl get serviceAccounts
NAME      SECRETS   AGE
default   1         43s
```

Nice! Ok, back to the DNS and busybox stuff.

```bash
❯ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                       READY   STATUS              RESTARTS   AGE
coredns-8494f9c688-2bz8x   0/1     ContainerCreating   0          88s
coredns-8494f9c688-pxw6f   0/1     ContainerCreating   0          88s
```

Without re-running anything it looks like the controller manager has picked up what
I ran before. Now I just have to wait a bit for it to create the container, I hope...

```bash
❯ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                       READY   STATUS              RESTARTS   AGE
coredns-8494f9c688-2bz8x   0/1     ContainerCreating   0          60m
coredns-8494f9c688-pxw6f   0/1     ContainerCreating   0          60m
```

I took the dog for a walk and came back to this. There's no way these containers should
take an hour to create, so something else is broken. Time for more learning!

Running `kubectl describe pods -l k8s-app=kube-dns -n kube-system` I get so much information
about what's not working, neat! I think the relevant part is:

`Warning  FailedCreatePodSandBox  58s (x369 over 86m)  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to create containerd task: cgroups: cgroup mountpoint does not exist: unknown`

searching isn't giving me a silver bullet solution to this, but it suggests there's something
wrong with my container runtime, so let's take a look at my worker node.

First thing to do is check the status of the services I was supposed to start.
`containerd`, `kubelet` and `kube-proxy` services all appear to be up and running.
I can see the same error about cgroup mountpoint not existing in `journalctl -xeu containerd`
so the problem is in there, but I'm still not sure what's actually broken.

Ok, with a little more context that I should be searching for that error in association
with containerd I find [this issue](https://github.com/kubernetes/minikube/issues/11310).

Now I have to figure out how to apply that to this guide. First let's check if there are
open issues in the repository to resolve it. There's a [PR](https://github.com/kelseyhightower/kubernetes-the-hard-way/pull/728/commits/2adb5c0f5cae7e9d3129a4d8ab9f2ff8daf8ffaf#diff-387650bdd066d5645818d0579c5d3d562ceac2c9c94bd176a9e3162bc9917e94)
to upgrade to a newer kubernetes, that includes a different way of generating the
containerd config file. I'm not sure how exactly to apply that in my example though.

I found a nice [PR](https://github.com/kubernetes/minikube/pull/11325/commits/813138734d347b3d84c527ed135fb37e509983f0)
in the minikube project that showed how to do the upgrade. After running it I got a little
better, but was still having some resolution errors and backoffs. I'd noticed some other
weird behaviour with my worker nodes so I decided to give them a reboot to see how that
worked.

After a reboot here's where I am:

```bash
❯ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                       READY   STATUS             RESTARTS   AGE
coredns-8494f9c688-2bz8x   0/1     ImagePullBackOff   0          3h30m
coredns-8494f9c688-pxw6f   0/1     ImagePullBackOff   0          3h30m
```

I ssh into a worker node and find that DNS no longer works on it. Controller nodes
still resolve hosts fine, and if I put in the IP of a local or external site I can ping
it. So something about how I configured that DNS service has broken things for my
workers. Hmmmm. Even more fun, after a bit of this, DNS on my entire home network broke.
I shut down all the nodes, rebooted my router and got DNS back.

After being afraid to touch this for a while I decided to start the nodes back up and see
what happened. Right now DNS is ok on my host machine at least. Connecting into my worker
nodes I can see that DNS doesn't work on two of them, and a whole bunch of extra network
interfaces have been created. That would definitely explain why I can't pull images. I
wonder if my earlier attempt to apply that manifest left something in a failed state that
they can't recover from. I give `kubectl delete -f coredns-1.8.yaml` a run to reverse the
playbook. I can't immediately resolve names on those nodes after running that, but let's
give them a reboot and see what happens. Ok, after a reboot DNS is back up. Let's try
applying that playbook again and see what happens:

```bash
❯ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                       READY   STATUS         RESTARTS   AGE
coredns-8494f9c688-jn25z   0/1     ErrImagePull   0          3s
coredns-8494f9c688-lhhg5   0/1     ErrImagePull   0          3s
```

So we're back to not working. At least the rest of my network is still ok for now.
Looking at the workers that are coming back up, I think I see something confusing.
The nodes that are running the coredns pods have a new network interface with an IP
that matches my router: `cnio0:`. I can still ping my router by its IP, and I can still
ping external sites if I know their IP, so routing isn't completely broken, but name resolution
seems to be. At this point I decided to confirm whether the weird network wide DNS failure
I had previously was indeed a result of this configuration. I rebooted my phone and when
it came back up DNS no longer worked. I deleted the manifest, rebooted my router, and
all was right with the world again. I don't even have my head around how this could happen,
let alone what it means. I guess that `cnio0` device is broadcasting that it has my router's
IP or something?

Reading through [this guide](https://github.com/ehlesp/smallab-k8s-pve-guide/blob/main/G017%20-%20Virtual%20Networking%20~%20Network%20configuration.md#g017-virtual-networking-network-configuration)
a bit, which is more focused on a homelab k8s deployment I can see that they had two
virtual network interfaces for the cluster, one for external facing connectivity, and one
for internal facing cluster communication. I think probably trying to do everything on
one network is part of what's causing me problems.

# Call it quits

At this point I feel like I'm hitting pretty serious diminishing returns in terms of
how much I'm learning vs how weird the edge cases I'm encountering are. I'm definitely
not done learning kubernetes, and I might even come back to this later, but I think there
are clearly some other aspects of my setup and kubernetes that I have to learn about more
before working through this will provide additional value.
