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

# Get bored and try and build databricks

Ok I lied. I still will be looking up docs and going through that, but I can't just
follow more tutorials to build another web app. The thing I actually want to do with
terraform right now is build a databricks environment based on their
[sample terraform modules](https://www.databricks.com/blog/announcing-terraform-databricks-modules).
Let's try that instead and see what I have to learn to do it properly.

Copy pasting in the modules is going to be too easy though, so let's just take from it
and figure things out as I go.

I'll start by looking at the [example adb-lakehouse](https://github.com/databricks/terraform-databricks-examples/tree/main/examples/adb-lakehouse),
and navigate into the modules it references as required.

The first file I check is `data.tf` which just has the azure config itself which
according to [the docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config)
will let me access things like my tenant and subscription ID. I'm sure that will come in
handy later.

# Naming things properly

We've got standards around how things should be named in Azure, and I'd like to follow
them as programmatically as feasible. The general naming convention is of the form
`<environment prefix>-<region>-<type of resource>-<what it's for>-<counter>`. So
a development resource group in the Canada Central region for testing databricks should
be called `D-CC-RG-DATABRICKSTEST-01` or something similar. I think there's a way to enforce
different types of object naming in terraform, but that seems more advanced than I want
to take on right now. I do at least want to be able to derive naming for environment
and region since I'm going to specify those as variables anyway.

To start I'll create a couple variables in `variables.tf` for the environment and region:

```terraform
variable "region" {
  type        = string
  default     = "canadacentral"
  description = "The region to deploy the workspace and all resources to"
  validation {
    condition     = contains(["canadacentral", "canadaeast"], var.region)
    error_message = "Region must be canadacentral or canadaeast"
  }
}

variable "environment" {
  type        = string
  default     = "development"
  description = "What sort of environment this relates to"
  validation {
    condition     = contains(["development", "uat", "production"], var.environment)
    error_message = "Environment must be 'development', 'uat', or 'production'"
  }
}
```

The `validation` block is a pretty cool feature, it lets me add additional constraints
other than data type.

The intuitive next step would be to create variables for environment and region prefixes
that are derived from these variables that can be referenced throughout the rest of the
code. Unfortunately, [that's not how this works](https://github.com/hashicorp/terraform/issues/17229).
For now in my `main.tf` I'll use some [locals](https://developer.hashicorp.com/terraform/language/values/locals)
to do this derivation. I think if I wanted to get fancier I could probably make a module
that would take those variables as inputs and return names as outputs that would be
reusable and extensible across my code base, but that's probably getting ahead of myself,
this is already feeling a bit over-engineered.

Anyway, in `main.tf` I can add locals like so:

```terraform
locals {
  environment_prefix = upper(substr(var.environment, 0, 1))
  region_prefix_map = {
    canadacentral = "CC"
    canadaeast    = "CE"
  }
  region_prefix = local.region_prefix_map[var.region]
}
```

There's maybe a way to inline that `region_prefix_map` local but it's not doing any
harm that I can see and this way feels more readable.

Now if I can create a resource group that will be dynamically named like this:

```terraform
resource "azurerm_resource_group" "this" {
  name     = "${local.environment_prefix}-${local.region_prefix}-RG-IPDATABRICKSTEST-01"
  location = var.region
}
```

Pretty neat! I'm starting to get my head around the terraform syntax too. The individual
syntax is all fine, but right now at least I'm struggling with combining elements of it
a little bit still.
