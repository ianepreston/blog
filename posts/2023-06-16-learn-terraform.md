---
title: "Learning terraform"
date: "2023-06-16"
description: "Let's try and get an associate cert"
layout: post
toc: true
categories: [terraform]
---

# Introduction

I've taken a crack at learning terraform before, [here](https://github.com/ianepreston/scratch/tree/main/electricpipe)
and more recently [here](2023-01-21-proxmox3.md). In both those cases my focus was to learn
by doing, rather than following a set curriculum. I still generally think that's a good
way to learn, at least at first. For one, it's motivating to have a tangible objective,
and for another, it lets you focus on the parts that are going to be important to you,
rather than whatever happens to be in the tutorial. On the other hand, doing things
that way can also lead to some pretty big gaps in understanding, and potentially limit
your capability with a tool or technique in the future. With that in mind, once I've learned
enough to know this is a subject worth learning, I like to supplement with some more structured
training to fill in those gaps and solidify my understanding. My plan to do that for
terraform is to go through the [associate study guide](https://developer.hashicorp.com/terraform/tutorials/certification-003/associate-study-003)
and then take the associate certification exam.

This post isn't a terraform tutorial, it's just going to be a collection of notes on
things I encounter while going through terraform tutorials that I either want to make
note of for myself, or think that others would find interesting.

# Terraform cloud

One thing I haven't done before with terraform is used terraform cloud. It's not officially
part of the learning path, but it seems like a good tangent to go down to start. I had
a hashicorp account created prior to this just for tracking my reading through the tutorials,
but I had to create an organization and a workspace to start the project. I pointed it
at my [scratch repository](https://github.com/ianepreston/scratch/tree/main) where I've
got a `learn_terraform` folder and set that as the root for the workspace. Any additional
config will come later. I'll probably have to attach some azure creds in there eventually
but I'll figure that out when I get to it.

Running `terraform login` prompted me to save an api key into my home directory. I'm using
a devcontainer so that's going to be a bit of a problem when I reload, but I'll worry about
that later too. The login did work at least. I'll add a `backend.tf` based on what's in
the [getting started repo](https://github.com/hashicorp/tfc-getting-started/blob/main/backend.tf)
but also won't be able to test that quite yet.

# Docker in docker

Some of the terraform tutorials provision local infrastructure with docker. I'm doing
all this from within a devcontainer so I need to set up a way to run docker commands
and create containers from within my container. I've updated my IaC devcontainer to
include docker-in-docker but it's going to take a while to rebuild so I'm going to come
back to this later.

# Azure and terraform cloud

Now I'm trying to combine two things at once. Always a good way to learn stuff. I've
got the terraform cloud config set and have logged in with `terraform login`. I've also
logged into Azure with `az login`. When I run `terraform plan` I get an error about
the Azure CLI not existing. I'm assuming that's in the remote space and I have to be
authenticated there? Let's see if I can have it plan locally and just store state
remotely to get around that. Changing from the `cloud` block to the `backend` block
doesn't just do this for me. I think I have to drop the cloud piece for now as well until
I can get cleared to create a service principal and provide its authentication into
terraform cloud. Lots of skipping things and coming back to it later so far in this learning
path.
