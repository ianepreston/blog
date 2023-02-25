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