---
title: "A couple notes on working with Nvidia cards"
date: '2023-06-04'
description: "I figured some stuff out at work and wanted to save it here"
layout: post
toc: true
categories: [docker, Linux, nvidia]
---

# Introduction

While helping the infrastructure team at work get Nvidia drivers working on a VM
virtualized on top of esxi and then getting that GPU to be available within rootless
docker containers I learned a couple things that I want to note down here.

# Installing nvidia drivers

So after I went and wrote a nice playbook to do this, I realized that nvidia
maintains their own [here](https://github.com/NVIDIA/ansible-role-nvidia-driver), so
in the future I would definitely just use this. I'm sure it would work better. One note
that I will add. In my experience, installing the CUDA version of the drivers is not worth
it. I was able to do GPU accelerated ML workloads without it, and installing them caused
me nothing but pain and suffering. Maybe it would go smoother with the official Nvidia role,
but I would suggest trying without unless you really know for sure you need them.

For posterity, here's how I installed Nvidia drivers:

```yml
# https://fabianlee.org/2021/05/19/ansible-installing-linux-headers-matching-kernel-for-ubuntu/
- name: Install dependencies
  ansible.builtin.apt:
    pkg:
      - linux-headers-generic
      - curl

- name: Get distribution name in the weird format nvidia wants it
  ansible.builtin.shell: |
    . /etc/os-release;echo $ID$VERSION_ID
  register: os_release

- name: Add nvidia gpg key
  ansible.builtin.shell: |
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg
  args:
    creates: "/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg"
  
- name: Add nvidia container toolkit repository to apt
  ansible.builtin.shell: |
    curl -s -L https://nvidia.github.io/libnvidia-container/{{os_release.stdout}}/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  args:
    creates: "/etc/apt/sources.list.d/nvidia-container-toolkit.list"

- name: update packages
  become: true
  ansible.builtin.apt:
    upgrade: "yes"
    update_cache: yes

# Headless 530 is the latest available as of 2023/5/16
- name: install nvidia driver and container runtime docker
  become: true
  ansible.builtin.apt:
    pkg:
      - nvidia-driver-525-server
      - nvidia-utils-525-server
      - nvidia-container-toolkit-base
      - nvidia-docker2

- name: Blacklist nouveau drivers
  become: true
  ansible.builtin.copy:
    src: nouveau-blacklist.conf
    dest: /etc/modprobe.d/nouveau-blacklist.conf
    owner: root
    group: root
    mode: '0644'
  notify:
    - Restart machine
```

Of particular note is the step to blacklist the nouveau drivers. I'm not 100% sure since
I didn't do either the bare metal or virtualized install on the systems I was testing this
on, but it appears that nouveau drivers get automatically installed on virtualized systems
on top of esxi. Because of that, you have to blacklist them or else you get all sorts of
esoteric errors that do a terrible job of telling you where the issue actually is.

# Extra stuff to make it work with rootless docker

A couple pieces of this got covered in the above section, specifically installing
`nvidia-container-toolkit-base` and `nvidia-docker2`. I'm not actually sure `nvidia-container-toolkit-base`
is required, I couldn't get anything working when I had just it installed, `nvidia-docker2` did the trick though,
along with the extra steps below.

```yml
- name: Add CDI support
  become: true
  ansible.builtin.shell: |
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  args:
    creates: "/etc/cdi/nvidia.yaml"

- name: Disable cgroups
  become: true
  ansible.builtin.lineinfile:
    path: /etc/nvidia-container-runtime/config.toml
    regexp: '^no-cgroups '
    insertafter: '^#no-cgroups '
    line: 'no-cgroups = true'
```

# Conclusion

If you want to install nvidia drivers on hosts using ansible, don't trust some hacked
together code from some guy on the internet, use the official Nvidia role. But if that
role doesn't handle rootless docker integration, or you run into weird issues getting it
working on VMs virtualized on top of esxi, take a look at this stuff and see if it helps
you out.