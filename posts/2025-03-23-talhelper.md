---
title: "My first k8s build log - talhelper"
date: "2025-03-23"
description: "Maybe a newbie perspective will be helpful"
layout: "post"
toc: true
categories: [kubernetes, talos]
---

# Introduction

I'm building out my first kubernetes cluster and in these posts
I'm going to do a relatively raw write up on what I've done to get
it working. These are definitely not authoritative guides, but I think
sometimes having someone who's new write up what they're doing can be
helpful. Hopefully it's useful to others, or at least me when I need to
go back and figure out what I did.

In this post I'm going to discuss using [talhelper](https://budimanjojo.github.io/talhelper/latest/)
to manage my talos linux install.

# Background

I've written in the past that I'm running my cluster on
[Talos Linux](https://www.talos.dev/), but I haven't written
about how I've configured it. That's mostly because I basically
followed [this blog](https://mirceanton.com/posts/2023-11-28-the-best-os-for-kubernetes/)
post verbatim, so I didn't have a lot to add personally.

That approach worked great for my initial setup, since all my machines
were the same, I wasn't worrying about upgrades yet, and I was using the base
version of Talos without extensions. As I spent more time using Talos though, I started
to run into shortcomings and after some research determined that I would be better
able to manage my config with talhelper.

As an aside, from the looks of [his repo](https://github.com/mirceanton/home-ops/blob/feat/cluster-bootstrap/kubernetes/bootstrap/talconfig.yaml),
the author of the blog I used as a template has made a similar leap.

## Specific issues I encountered

### Upgrade woes

Talos warns that you should use the same version of `talosctl` as you're
running on your cluster. I learned the hard way why that is.

Because I wasn't pinning my version of `talosctl` (that's a little tricky
to do with nix and I didn't think it was a big deal at the time), when
I ran commands like `talosctl gen config` it created a config that assumed
I would have a newer version of kubernetes than what was associated with
the version of talos I was running. Talos and Kubernetes versions are
normally very tightly coupled and you should be managing them in lockstep.

Because I didn't understand this, I wound up running an old version of talos
with a new version of kubernetes. This put me in a tricky situation. You can't
roll back your kubernetes version in talos (at least I couldn't figure out how),
and I also couldn't upgrade talos to the next version I needed to get to (major
version upgrades are only supported from the latest minor version of the previous
major revision). I eventually resolved it by wiping my cluster and reinstalling
fresh. Fortunately I didn't have anything important running, this sort of thing is
exactly why I'm going to run a dev version of the cluster for quite a while before
I'm comfortable putting workloads I care about on it.

The discussion related to this issue is [here](https://github.com/siderolabs/talos/discussions/10447).
I do think there's some opportunities for Talos to improve how it handles coupling
k8s and talos upgrades, but ultimately the issue was still mine.

### Machine specific configs

My old approach works fine as long as I treat all my nodes (at least within control planes and workers)
as identical. While this is the case for me for now, I can see a time when it won't be, or
where I might want to build up my config by explicitly referencing MAC addresses or other
hardware device IDs on nodes rather than just saying "use the only physical NIC in the machine"
for example.

### Handling custom images

My initial install of talos was just the vanilla build you can download from their site.
As I'm starting to experiment with things like [longhorn](https://longhorn.io/)
I'm discovering I need to build custom images from [talos factory](https://factory.talos.dev/).

My initial solution to this was to write my own parser script that read in a yaml file with
the customizations I needed, called the factory API, and retrieved the unique ID I needed,
which I could then feed into install commands.

This worked, but it was custom logic I had to maintain, and it didn't address my upgrade
woes issue above.

### Issues summary

All of these issues can be summed up as needing to write or maintain custom logic to
generate configs for upgrading or reconfiguring talos. I'm sure I could have come up with
my own fixes for the first two and I did for the third, but at this point I'd also read
about talhelper, and it seemed like it was handling all the problems I was facing, plus
probably some additional ones I hadn't thought of.

# Installing talhelper (and having working talos configuration environment generally)

Talhelper comes with install guides for a variety of package managers, including
[nix flakes](https://budimanjojo.github.io/talhelper/latest/installation/#using-nix-flakes),
which is my current preferred way of setting up my environments. However, their instructions
didn't play nicely with some other components of my nix setup, so I did have to do things a
bit differently. Since I haven't documented it elsewhere, I might as well explain
my setup here in general.

I've got one `homelab` repository (private for now at least because I'm still
slightly paranoid about leaking something sensitive even though I'm making efforts
not to) with base directories under it for each service it manages. Relevant to this
discussion that means there's a `talos` directory for managing the nodes and base
kubernetes installs themselves, and then a `k8s` directory for the services I run
on those clusters. In the root of `talos` I have a `flake.nix` that configures
my dependencies:

```nix
{
  description = "Setup env for working in my kubernetes clusters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    talhelper.url = "github:budimanjojo/talhelper";
  };

  outputs =
    {
      self,
      nixpkgs,
      talhelper,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            talhelperPkg = talhelper.packages.${system}.default;
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs, talhelperPkg }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              talosctl
              talhelperPkg
              kubectl
              kubernetes-helm
              clusterctl
              cilium-cli
              bws
            ];
          };
        }
      );
    };
}
```

It's very similar to how the talhelper docs suggest to install it, but something about my
`supportedSystems` setup didn't play nicely with the overlay they suggest. Defining
`talhelperPkg = talhelper.packages.${system}.default;` and then including that in my
list of packages was the secret sauce to get it working in my case.

Below this directory I have directories for each cluster I want to maintain, for now that's
only `dev`, but eventually this will include a `prod` folder as well. In that directory
I have another flake that builds upon this parent flake and adds environment specific stuff:

```nix
{
  description = "Setup Talos config for my dev cluster";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = import nixpkgs { inherit system; }; });
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            shellHook = ''
              export TALOSCONFIG="$(pwd)/clusterconfig/talosconfig"
            '';
          };
        }
      );
    };
}
```

The `.envrc` in this directory then applies both flakes:

```
source_env ../.envrc
use flake
```

With this all set up when I navigate to the directory for my cluster
I have all the tools I need and my environment variables are automatically
set to use the correct cluster. I think my envrc could probably
just set the one extra environment variable itself rather than use a flake,
but I started out with some extra stuff in here and it's less work to
just leave it.

# Setting up talconfig

## Create secrets

Talhelper defaults to expecting you to use sops and age for encrypting
secrets. Fortunately that's the approach I was already taking.
For some reason my old approach seemed to be ok with having one
`.sops.yaml` file in the base `talos` folder but talhelper wanted
it right in `dev`. Not a big deal, there's very little content
in it but I did find that odd. Other than that I followed
the instructions to retrieve my secrets from my running
cluster and put them into the format talhelper expects
using [their docs](https://budimanjojo.github.io/talhelper/latest/getting-started/#you-already-have-a-talos-cluster-running).

## Converting over configs from patch format to talhelper

A lot of the configs are quite straightforward to port, but there were
some where I had to do some digging around. The docs for talhelper are
quite good, but they don't cover every scenario. Fortunately there are people braver
than me who have open sourced their repos and by looking at their examples I was
able to figure out what I needed to do. My config ended up looking like this:

```yaml
clusterName: dk8s
talosVersion: v1.9.5
kubernetesVersion: v1.32.3
endpoint: https://192.168.40.13:6443 # Talos endpoint, the VIP
allowSchedulingOnControlPlanes: true
cniConfig:
  name: "none"
patches:
  - |-
    cluster:
      proxy:
        disabled: true
controlPlane:
  patches:
    - |-
      - op: add
        path: /machine/kubelet/extraMounts
        value:
          - destination: /var/lib/longhorn
            type: bind
            source: /var/lib/longhorn
            options:
              - bind
              - rshared
              - rw
  schematic:
    customization:
      extraKernelArgs:
        - net.ifnames=0
worker:
  patches:
    - |-
      - op: add
        path: /machine/kubelet/extraMounts
        value:
          - destination: /var/lib/longhorn
            type: bind
            source: /var/lib/longhorn
            options:
              - bind
              - rshared
              - rw
  schematic:
    customization:
      extraKernelArgs:
        - net.ifnames=0
nodes:
  - hostname: "d-hpp-1-lab"
    ipAddress: 192.168.40.11
    networkInterfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip: &vip
          ip: 192.168.40.13
    installDisk: /dev/nvme0n1
    controlPlane: true
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/intel-ucode
            - siderolabs/iscsi-tools
            - siderolabs/util-linux-tools
  - hostname: "d-hpp-2-lab"
    ipAddress: 192.168.40.7
    networkInterfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip: *vip
    installDisk: /dev/nvme0n1
    controlPlane: true
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/intel-ucode
            - siderolabs/iscsi-tools
            - siderolabs/util-linux-tools
  - hostname: "d-hpp-3-lab"
    ipAddress: 192.168.40.9
    networkInterfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip: *vip
    installDisk: /dev/nvme0n1
    controlPlane: true
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/intel-ucode
            - siderolabs/iscsi-tools
            - siderolabs/util-linux-tools
```

I don't love the `patches` syntax but I couldn't find a better way.
Maybe future releases will add top level arguments for this.

One of the trickier parts was figuring out what stuff to put in
the contol plane/worker layer and what to put in the node
layer. Some things like `networkInterfaces` have to be
on the node level even though in my case they're the same
across all devices. Most things if you define them at the
control plane/worker level and also at the node level the node
argument will override. There are ways to work around this but I
didn't bother since repeating myself a little on the node
level is not a big deal. Eventually it would be nice to get
this even more modular, but I've got a lot of other things
I want to do with this cluster so I have to recognize when I'm at
a good enough state.

## Applying the configuration

Talhelper ships with some nice syntax to turn this configuration
back to standard talos config files and commands so this part
was straightforward. `talhelper genconfig` makes a `clusterconfig`
directory and adds its contents to gitignore since it contains unencrypted
secrets. After that you can generally run `talhelper gencommand <command>`
to get the associated `talosctl` commands. You can pipe this directly to
bash to immediately run the command (across all your nodes) but for now
I'm happy to take the output and run each step manually. One thing I couldn't
figure out was how to have it add flags. My immediate use case is adding
the `--preserve` flag on `upgrade` commands so it doesn't wipe out my persistent
volumes during upgrades. It's easy enough to just take the command it generates
though and add the flag yourself, just have to remember to do it.

I ran through patching talos and kubernetes as well as applying
updated configs and everything ran fine.

# Conclusion

Switching from raw (or personally scripted) handling of talos
configuration to talhelper took a bit of work, but I'm confident it
will be worth it in the long run for maintainability and extensibility.

