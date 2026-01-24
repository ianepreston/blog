---
title: "My first k8s build log - Terraform"
date: "2026-01-23"
description: "Not everything lives in the cluster"
layout: "post"
toc: true
categories: [kubernetes, talos]
---

# Introduction

Continuing my rebooted cluster setup series, let's talk about how I use
terraform.

# Setting up terraform

As mentioned in my [environment](./2026-01-23-cluster-env.md) post, I use
Hashicorp's cloud service to manage my values and state. Initially I ran
terraform itself in their cloud, which was fine when I was only talking to my
Bitwarden Secrets Vault and Cloudflare, since they were both reachable from
outside my network. Recently I've been using it to also manage
[authentik](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs),
since I want to be declarative for as much as possible and the actual
configuration can't be handled by kubernetes manifests. Since authentik runs in
my cluster, it's not reachable by terraform's hosted agents. To get around this
I created an agent token and configured a docker container running `tfc-agent`
which will pick up any terraform commands I call and run them from within my
network. The setup for the container is
[in my flake](https://github.com/ianepreston/homelab/blob/f616ca6e28c7e0129aac4031ca59a310175fb07f/flake.nix).
It's a little overkill in that it kills and restarts the container every time I
start a shell in my homelab directory, but it seems to work fine.

# Kubernetes stuff

I do only a couple things to set up my cluster with terraform and honestly both
of them are kind of silly. I did it as a learning experience but wouldn't
recommend it as an approach for anyone else.

[The first](https://github.com/ianepreston/homelab/blob/6910de24a6b334e9a26a7742ee05def1f621edaf/terraform/k8s/cert-manager.tf)
is that I make a Cloudflare token that can write DNS records. This is used by
cert-manager to make
[dns challenges](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
to get certificates I can use to give my services proper TLS certs through
letsencrypt. It's not that having this itself is silly, but I need to manually
create an API token with permission to create other API tokens and add it to
terraform, so I can use it to... make an API token. I could have just made the
token myself and directly saved it to my Bitwarden vault. Plus the cloudflare
provider has introduced breaking changes a few times while I've been working on
this project. Honestly, I just wanted this as an excuse to have some terraform
in my setup and mess around with it. Don't be like me kids.

[The second](https://github.com/ianepreston/homelab/blob/d91b4fc15551d490b284a4141dae5cc056ba75d1/terraform/k8s/authentik.tf)
is to generate random passwords and tokens for authentik and then save them to
Bitwarden. Again, I could have just generated some passwords myself and saved
them to my vault in less time than it took me to write this code and then I
wouldn't have to worry about the secrets being in my state file as well as my
vault. At least I talked myself out of doing this for all my other tokens and
passwords before this really got out of hand. I will probably remove this and
just do the manual approach, but I'm also considering switching from authentik
to zitadel, so it's low on my list.

# Authentik stuff

This part is actually useful. Even if I do switch to zitadel, I'll do something
like this. This repo creates all the resources within authentik that are
required for it to act as an identity provider or secure gateway for my cluster
apps. For apps that don't have their own auth it sets them up as a proxy so my
gateway knows to check with authentik before redirecting users to the underlying
page and for apps that have their own auth it makes all the required application
and oauth resources.

I've seen other repos that seem to have a terraform controller within the
cluster that would make it possible to bring something like this under
management by flux (I think), but for how often I add apps or whatever I'm happy
to hit `terraform apply` myself for now.
