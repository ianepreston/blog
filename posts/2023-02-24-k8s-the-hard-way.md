---
title: "Notes on Kubernetes the hard way"
date: '2023-02-24'
description: "What better way to learn k8s than implementing it?"
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

# Provisioning a CA and Generating TLS certificates

On to [chapter 4](https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md) in the guide!

I have to do some minor modification of the scripts outlined in the doc since I'm not
using GCP. I think for these future configs I'm going to use ansible, since that's how
I'd like to actually manage hosts in the future.