---
title: "Working Templates in Xen-Orchestra"
date: '2023-12-11'
description: "That last post sure didn't work. Let's try this"
layout: post
toc: true
categories: [linux, virtualization, xcp-ng]
---

# Introduction

In my [last post](2023-11-27-packer.md) I spent entirely too long trying to figure out
a fancy automated way of building image templates on xcp-ng/xen-orchestra. While I
definitely learned a lot, I also spent more time trying to figure out an automation
to build templates than I'll reasonably spend doing it manually for the next few years.

This post is a quick summary of my approach for (manually) building templates for the
distros I want to have available in my homelab.

# Ubuntu

Always nice to have an Ubuntu or two around, even if I'm not a big fan of snap and
some of the other stuff they've added. I basically follow the approach in 
[this post](https://sysmansquad.com/2021/07/07/creating-an-ubuntu-20-04-cloud-template-cloud-init-configuration-in-xen-orchestra/)
so all credit there. I'll still write it out here in case that site goes down or something.

- Download the image you want. The base URL is [here](https://cloud-images.ubuntu.com/)
  head to the release folder you want, go to `current` and then find the `.ova` file.
  Right now the LTS release is focal fossa and the link for it is
  [here](https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.ova)
- In XO head to Import, then VM. Note that you can't import OVA files directly from URL,
  hence the download in the previous step.
- Select the pool and SR you want to import to, then drop the file you downloaded into
  the box.
- Double check the VM information. It should be fine since we're just making a template.
  Once you're happy, click import.
- When the import finishes it should take you to the VM page. If it doesn't you'll have
  to find it, remember to turn off the default running filter on the xo page.
- From the VM page go to the advanced tab and click "Convert to template"
- If you head to the templates page on XO and search for Ubuntu you should have a new
  one. In my case it's named "ubuntu-focal-20.04-cloudimg-20231207"
- Copy this template to any other hosts you want to use it on. From the templates page
  check the box beside the template (or wait until you've made all the ones you want
  to save time) and click the copy icon. Probably remove `_COPY` from the name section,
  pick your SR and copy.

## Cloud config

Test creating a VM from the template. My Ubuntu cloud config (slightly edited) is as
follows:

```yml
#cloud-config
hostname: {name}%
users:
  - name: ipreston
    ssh_authorized_keys:
      - ssh-ed25519 <MY KEY>
packages:
  - xen-guest-utilities
```

I also give it a 20G disk to make sure the resizing performed correctly.