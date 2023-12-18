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

General pro tip: Use the snapshot feature liberally while you're building your reference
images in case you mess up.

# Arch

I'm a big fan of Arch. My main bare metal server runs it, and it's what I like to run
for a personal OS as well, so having a good template for it would definitely be handy.

I basically did this in the last post, but the notes are pretty scattered so this will
be a cleaned up version.

- Create the VM. Base it on the Ubuntu Jammy template, give it 4 cores, 4GB RAM and 10GB disk
- Boot into the live environment and set the root password with `passwd`, check your IP with `ip address`
  - This is so you can do the rest of the install [over ssh](https://wiki.archlinux.org/title/Install_Arch_Linux_via_SSH)
- ssh in with `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@ip.address.of.target`
- run `archinstall`
  - Pick `Canada`, `United States` and `Worldwide` for mirror selection
  - Leave locales at `en_US`, we'll add Canada later and lots of packages seem to need that locale
  - Use a best effort default partition layout with `ext4` format
  - Pick `Limine` for the bootloader, why not?
  - Keep the hostname as `archlinux`
  - Leave root password blank to disable root
  - Add a user, might as well make it my actual username, one less thing to change and I'm
    the only one using this template
    - Give them a password and sudo access
  - Pick `minimal` for profile
  - Don't add an audio server
  - Just the `linux` kernel, no hardened, zen, lts
  - Install the following additional packages: `vim openssh reflector git base-devel nfs-utils`
  - Set network configuration "Use NetworkManager"
  - Update the time zone
  - Leave NTP on
  - Install
  - Don't `chroot` in, just reboot
- `sudo systemctl start sshd.service && sudo systemctl enable sshd.service`
- ssh back in so you don't have to use the XO portal anymore.
- `sudo reflector --latest 200 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist` ([docs](https://wiki.archlinux.org/title/Reflector))
- `sudo pacman -R reflector` maybe I'll set it up on a timer but if I do it'll be with ansible or something
- Install yay: `git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si`
- Clean up `cd .. && rm -rf yay`
- Install guest agent: `yay -S xe-guest-utilities-xcp-ng`
- Enable it `sudo systemctl enable xe-linux-distribution.service`
- Setup passwordless sudo `sudo EDITOR=vim visudo /etc/sudoers.d/00_ipreston`
  - Change the line to `ipreston ALL=(ALL:ALL) NOPASSWD: ALL` 
- Install cloud init: `yay -S cloud-init cloud-guest-utils`
- Set default user in cloud config, just change the default user line in `/etc/cloud/cloud.cfg`
- Add the post install host signing script to `/etc/ssh/sign_host.sh`. This won't help anyone else but it's useful for me

```bash
#!/bin/env bash
set -e
mkdir /tmp/hostkeys
mount -t nfs laconia.ipreston.net:/volume1/keys /tmp/hostkeys
cp /tmp/hostkeys/user_ca.pub /etc/ssh/user_ca.pub
chown root /etc/ssh/user_ca.pub
chmod 600 /etc/ssh/user_ca.pub
cp /tmp/hostkeys/host_ca /etc/ssh/host_ca
chown root /etc/ssh/host_ca
chmod 600 /etc/ssh/host_ca
cp /tmp/hostkeys/setup_host.sh /etc/ssh/setup_host.sh
umount /tmp/hostkeys
bash /etc/ssh/setup_host.sh
rm /etc/ssh/host_ca
rm /etc/ssh/setup_host.sh
```
- `sudo chmod +x /etc/ssh/sign_host.sh`
- Get ready for cloud init:
  - `sudo systemctl enable cloud-init.service`
  - `sudo systemctl enable cloud-final.service`
  - `sudo cloud-init clean`
  - `sudo poweroff`
- Make a clone so you can go back to this one after you make the template
- Rename the clone to be a template name
- Turn it into a template
- Make a cloud config:

```yml
#cloud-config
hostname: {name}
runcmd:
 - "sudo /bin/bash /etc/ssh/sign_host.sh
```
