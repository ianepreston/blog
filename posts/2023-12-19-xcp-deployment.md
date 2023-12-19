---
title: "Deploying and configuring machines in Xen-Orchestra"
date: '2023-12-19'
description: "Deploy and configure some images from my hard fought templates"
layout: post
toc: true
categories: [linux, virtualization, xcp-ng, terraform, ansible]
---

# Introduction

Having successfully [built some template images](2023-12-11-xcp-templates.md) it's
time to provision and configure some machines using terraform and ansible. Honestly
using terraform is way overkill for the number of machines I'm actually planning to
deploy, but it's a nice way to document what I'm doing, and I'm expecting it to be
relatively straightforward to get going.

# Set up terraform

Locally I configure the code to run in my IaC devcontainer, which has terraform, ansible
etc. preinstalled. For state management in terraform I'm going to try terraform cloud.
I've only used local and ADLS storage backends before, but for personal use the cloud
backend is free. I'll be doing local execution of course since terraform cloud runners
don't have access to my homelab.

I set up a new `homelab` project in my account and then go to create a workspace. I go
with CLI-Driven workflow since I won't be doing any automated triggers of this provisioning.
I'm just going to name the workspace `homelab` as well. Even though I will have dev and
prod images they're not going to match closely enough to have actual separate workspaces
make sense (I don't think, again, just using terraform for the handful of VMs I'm making
seems excessive). After updating my organization default the workspace is set for local
execution, which is what I want.

Next I create a `backend.tf` file to store the workspace information. The workspace shows
a sample block for terraform when I create it so I just add that. In the same block
I add the required providers info for the [XO provider](https://registry.terraform.io/providers/terra-farm/xenorchestra/latest).

After that I login with `terraform login`, I'm not sure if my devcontainer is going to
persist the token I added so I may have to mess with this later, but let's leave it for now.

Next I run `terraform init`, which creates a local statefile, but it only points to my
cloud backend, at least for now, so maybe that's fine. It's in `.terraform` and I've got
that in `.gitignore` anyway. (Update, it only ever contained backend info)

After that I need to set up the provider to connect to my specific XO instance. From the
provider docs I can set environment variables for the host, username, and password. I'll
use my usual pattern to retrieve those from bitwarden and put them in a script that I can
`eval $(cat <secrets>)` in other scripts. This keeps them out of my repo but means I don't have to retrieve
them every time. I then make a very sparse `provider.tf` file since I only have one provider
and basically everything is set in environment variables. The only thing I have to specify
is to not use SSL. At some point I will get around to generating proper certs for all
this stuff, but that is not today. The exact way I got the environment vars set was from
following [this blog](https://xen-orchestra.com/blog/virtops1-xen-orchestra-terraform-provider/).
The way I was doing it before wasn't making the variables show up for terraform even though
I could see them in my shell. I really don't get environment variable scoping in bash.

As a first step let's just try getting some data resources. I'll need those anyway to
create VMs, and it's a nice way to make sure my setup is working. I create a `dev-data.tf`
file and add info for my pools. After that running terraform plan shows no changes, which
means that it's at least connected and read the resources. Great!

# Deploy a VM

There's a couple things I might eventually add to this, like configuring virtual networks,
but let's not get ahead of ourselves and try just deploying a VM.

Setting up the data blocks felt a little repetitive. I have to create SRs and Network
objects for each pool, but that's on me for managing each host as its own pool. In the
end with a little hacking it wasn't that hard to do. I'll show the examples of the
components I created and describe them a bit below:

```hcl
data "xenorchestra_pool" "dhpp3" {
  name_label = "d-hpp-3"
}
```

This is the pool I'm deploying to, it's a 1:1 mapping between pools and hosts for me, but
the VM cares about the pool it's being deployed to so this is what I need to bring in.

```hcl
data "xenorchestra_sr" "dhpp3" {
  name_label = "Local storage"
  pool_id    = data.xenorchestra_pool.dhpp3.id
}

data "xenorchestra_network" "dhpp3" {
  name_label = "Pool-wide network associated with eth0"
  pool_id    = data.xenorchestra_pool.dhpp3.id
}

data "xenorchestra_template" "arch-dhpp3" {
  name_label = "archbase_template"
  pool_id    = data.xenorchestra_pool.dhpp3.id
}
```

Each host has local storage, which is where I want VMs deployed. Terraform needs the local
storage for each host to be uniquely identified (it can't infer it from which pool I'm
deploying to) so I need to pass in the pool id and create one for each pool. The same
goes for my network and template configs.

```hcl
resource "xenorchestra_cloud_config" "d-mars" {
  name = "d-mars-cloudconfig"
  # Template the cloudinit if needed
  template = templatefile("arch-cloud.tftpl", {
    hostname = "d-mars"
  })
}
```

I can't use the XO templating in my terraform cloud configs, so I have to create a new
one for each VM if I want to dynamically assign the hostname. The template file I reference
looks basically like the cloud config I created for manual template deployment, just with
terraform variable substitution instead:

```yml
#cloud-config
hostname: ${hostname}
runcmd:
 - "sudo /bin/bash /etc/ssh/sign_host.sh"
```

```hcl
resource "xenorchestra_vm" "d-mars" {
  memory_max       = 4294967296
  cpus             = 2
  cloud_config     = xenorchestra_cloud_config.d-mars.template
  name_label       = "d-mars"
  name_description = "Dev VM for Docker host machine"
  template         = data.xenorchestra_template.arch-dhpp3.id
  exp_nested_hvm   = false
  auto_poweron     = true
  wait_for_ip      = true


  # Prefer to run the VM on the primary pool instance
  affinity_host = data.xenorchestra_pool.dhpp3.master
  network {
    network_id = data.xenorchestra_network.dhpp3.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.dhpp3.id
    name_label = "d-mars"
    size       = 21474836480
  }

  tags = [
    "dev",
    "arch",
  ]
}
```

Finally I can create the actual VM. Most of the hard work is done in the data blocks
above. Specifying disk and RAM in bytes is a bit of apain, but otherwise it's quite
straightforward. The deploy was actually pretty quick. I definitely remember this step
hanging forever when I was messing around with it in proxmox, but this machine got up
and running about as fast as if I'd manually provisioned it, so that was great.

# Set up ansible

Now that I've deployed a VM I need to configure it.

## Dynamic inventory

I could just hard code in inventory entries for the VMs I create, but where's the fun
in that? There's a [xen-orchestra-inventory](https://docs.ansible.com/ansible/latest/collections/community/general/xen_orchestra_inventory.html)
plugin that looks like what I want.

### Run into issues

I create a dynamic inventory file similar to what's shown in the docs and
[this blog](https://xen-orchestra.com/blog/virtops3-ansible-with-xen-orchestra/) from
xen-orchestra. I get an error about failing to parse it though when I run
`ansible-inventory -i inventory.xen_orchestra.yml --list`. Running again with the
`-vvv` flag for max verbosity I get a slightly more descriptive error about
`declined parsing /workspaces/homelab/ansible/inventory.xen_orchestra.yml as it did not pass its verify_file() method`

Reading a little more carefully the issue is actually this part:

```bash
[WARNING]:  * Failed to parse /workspaces/homelab/ansible/inventory.xen_orchestra.yml with auto plugin: This plugin requires websocket-client 1.0.0 or higher:
https://github.com/websocket-client/websocket-client.
```

I think maybe this is why the ansible docs recommend installing it with pip. Maybe I'll
rework my devcontainer later. For now I'll try the following:

```bash
sudo apt update
sudo apt install python3-pip
pip3 install websocket-client
```

Ok, that fixed it. I'll clean up my devcontainer later to address this.

### Hide sensitive info

During initial testing while I was figuring out the inventory plugin I just hard
coded my username and password into the inventory spec. That clearly won't cut it long
term. I tried creating an ansible-vault encrypted variable with my username and password,
setting the plugin variables to pull from there, and then running the inventory command
with `--extra-vars variables/secrets.yml`, but it didn't like that. Fortunately the
plugin will accept environment variables, so I did the same basic approach as I did
with terraform to pull the info from Bitwarden, put it in a gitignored shell file,
and then export those variables before calling ansible.

## Ping hosts

The dynamic inventory also picks up my actual xcp-ng hosts, which I don't really want
to interact with via ansible. I'd like to figure out how to just connect with the
VMs I actually care about, so let's try a few things with a basic playbook that just
uses the `ping` module to establish connectivity. I can add some groups to my inventory
selecting based on tags. I can't figure out how to do it based on hostname for specific
stuff though, so I'm going back to terraform to update and just add an actual hostname
tag to the machine I provisioned. This also happens to be a nice way to make sure I can
modify a VM non-destructively with terraform.

With that set up I make a basic playbook with one ping task for the group that I identified
(which only has one member) above. It works!

## Summarize the ansible setup

Doing actual configuration stuff is out of scope for what I want to cover in this
post, so let's wrap up with the pieces I put together to get this working

I make sure the collection that contains the XO inventory plugin I need is installed
by making a file in `./collections/requirements.yml`:

```yml
---
collections:
  - name: community.general
```

I can update that later with additional plugins for specific provisioning tasks.

I call it at the top of deployment scripts to be safe with `ansible-galaxy collection install -r ./collections/requirements.yml`
although that should only have to be done once.

The credentials to XO is the same as I documented in terraform so I'll leave that out.

I have a few pieces in `ansible.cfg` to set up the environment:

```ini
[defaults]
remote_user = ipreston
interpreter_python = /usr/bin/python3
```

The last line isn't strictly necessary but it silences a warning I get otherwise.

The dynamic inventory file looks like this:

```yml
---
plugin: "community.general.xen_orchestra"
validate_certs: false
use_ssl: false
groups:
  arch: "'arch' in tags"
  dev: "'dev' in tags"
  dmars: "'d-mars' in tags"
```

Again, gotta set up ssl eventually, but not today.

The actual playbook looks like this:

```yml
---
# Playbook for my dev mars box

- name: Example from an Ansible Playbook
  hosts: dmars
  tasks:
    - name: Just ping it
      ansible.builtin.ping:
```

Finally, the bash script that ties it all together and is what I actually run to configure
the deployed machine is this

```bash
#!/bin/env bash
bash _requirements.sh
bash _get_creds.sh
eval $(cat creds.sh)
ansible-playbook -i inventory.xen_orchestra.yml d-mars.yml
```

# Look into hooking terraform and ansible together

This is definitely overkill but it seems fun to look into, what if I want to have ansible
run a playbook on a resource as soon as it's provisioned by terraform?

There is an [ansible provider for terraform](https://registry.terraform.io/providers/ansible/ansible/latest/docs)
and a [terraform provider for ansible](https://github.com/ansible-collections/cloud.terraform)

The ideas seem interesting, but the terraform provider for ansible seems to want to create
its inventory from terraform, which conflicts with the XO inventory I just set up, and I
don't really understand how the terraform provider works. I think this is well into overkill
territory for now so I'm going to leave it alone.

# Conclusion

In this post I went over the basics of deploying machines on xen-orchestra using terraform
and then configuring those deployed machines with ansible, although not in a 100% end
to end integrated fashion.
