---
title: "Install Microsoft ODBC drivers with ansible"
date: '2023-06-04'
description: "There's a couple small tricks"
layout: post
toc: true
categories: [Linux, ansible]
---

# Introduction

This is a quick note on how to set up Microsoft ODBC drivers using ansible. Most of it
is quite trivial, but you can run into issues with the Microsoft repository version of
dotnet conflicting with the one from the base Ubuntu repository, and this playbook
addresses that.

# How to do it

```yml
- name: Install odbc pre-requisites
  ansible.builtin.apt:
    pkg:
      - lsb-release

- name: Add microsoft gpg key
  ansible.builtin.shell: |
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg && \
    chmod a+r /etc/apt/keyrings/microsoft.gpg
  args:
    creates: "/etc/apt/keyrings/microsoft.gpg"

- name: add Microsoft repository to apt
  apt_repository:
    repo: "deb [arch=amd64,armhf,arm64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/{{ansible_distribution_version}}/prod {{ansible_distribution_release}} main"
    state: present

- name: Prioritize Microsoft repo so you don't end up with dotnet conflicts if you need it later
  ansible.builtin.copy:
    src: "99-microsoft-dotnet.pref"
    dest: "/etc/apt/preferences.d/99-microsoft-dotnet.pref"

- name: Install odbc drivers
  ansible.builtin.apt:
    pkg:
      - msodbcsql18
  environment:
    ACCEPT_EULA: "Y"
```

The `99-microsoft-dotnet.pref` file is simple and looks like this:

```conf
Package: *
Pin: origin "packages.microsoft.com"
Pin-Priority: 1001
```

# Conclusion

I'm not going to do a bunch of exposition on this. If you're in the very specific
circumstance of needing to install Microsoft ODBC drivers with ansible I hope this helps.