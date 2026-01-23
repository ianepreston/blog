---
title: "My first k8s build log - Local environment"
date: "2026-01-23"
description: "I rebuilt most of it from scratch"
layout: "post"
toc: true
categories: [kubernetes, talos]
---

# Introduction

I've done a ton of work on my homelab cluster since the last post, but I haven't
been keeping up with writing about it. To cement my knowledge I'm going to pause
what I'm working on and go back and try and document how I have things set up
before I forget too much of what I did and why.

This first post in the (rebooted) series will cover how I set up my local
environment so I can work on my machines.

A quick note, I'm going to try and remember to make all the links to files in my
repo point to the latest commit they had at the time of this writing. If you
want to see how things have evolved, check the main branch for that file
instead, but this way should keep the code consistent with what I'm writing.

# Packages and environment variables

Even though my goal for cluster administration is to be as close to fully GitOps
driven as possible, I still need lots of tools locally to write the things that
get deployed to the cluster and to troubleshoot issues when they come up. I make
sure all of these tools are available using a
[nix flake](https://github.com/ianepreston/homelab/blob/f616ca6e28c7e0129aac4031ca59a310175fb07f/flake.nix).
This not only installs a bunch of cli tools I use like `kubectl`, `go-task`, and
`bws`, it also has a shell hook to start a container running a terraform build
agent. More on that in a subsequent post, but it lets me run terraform
operations on things like my cluster that don't have external network
connectivity while still using Hashicorp's terraform workspace to store my state
and sensitive variables. In addition to the flake I use
[direnv](https://github.com/ianepreston/homelab/blob/f17f8cda673a4099d27939533ba9b4ff3e418128/.envrc)
to activate my flake and source some environment variables when I enter the
repository.

Speaking of environment variables, there are a couple things that go into that.
Some of my environment variables are sensitive, or related to accessing
sensitive things at least, so I have a `bws.env` file that exports my Bitwarden
Secrets access token to an environment variable (sourced by direnv). From there
I can run `bws` commands to get secrets that I need as environment variables.
Obviously `bws.env` is in my `.gitignore` since I don't want to push that token
to my repository. The first time I clone the repo on a new machine I have to
manually add that file, but that's about it for setup.

I've also got a task in my
[root taskfile](https://github.com/ianepreston/homelab/blob/840f27194791bf6d29ccb728bb2600f33652bd4c/Taskfile.yaml)
that will populate a `k8s.env` file with additional environment variables to
configure connectivity to a specific cluster. If I just call `task set_context`
it will set me up for my dev cluster, which is where most of my work happens,
but I can override it with `task set_context CLUSTER=prod` to work on my prod
cluster.

# Tasks

Speaking of tasks, for commands I'm going to want to run as part of cluster
setup or on a regular basis I try and add a
[task in a taskfile](https://taskfile.dev/). This interacts nicely with all the
environment variables I set up in the above section, so if there's something a
bit complicated that I won't have to do often (like bootstrap a fresh cluster)
or just something I do regularly that I want to shorten (like run an ansible
playbook for my old non-kubernetes setup) I can make a task for it and remember
what to do without having to memorize long commands. It blurs the line a bit
between utility and documentation in my head. I've got my default task to be
listing all my tasks so if I just run `task` I can see what all I've got set up.
Besides the root taskfile I linked in the previous section everything else lives
under the `taskfiles` directory to help break up the task list and make it a bit
easier to find what I'm looking for.
