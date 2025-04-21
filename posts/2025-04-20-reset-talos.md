---
title: "My first k8s build log - resetting"
date: "2025-04-20"
description: "GitOps is starting to pay for itself"
layout: "post"
toc: true
categories: [kubernetes, talos]
---

# Introduction

As I've been messing around with setting up this cluster, particularly when it comes to
persistent storage, I've found that sometimes I want to start with a clean slate.
Technically I'm sure there's a better way to recover from some of the messes I've gotten
into, and I generally try for quite a while before I resort to pulling the plug, but this
is a dev cluster so being able to tear it down and start again is important.
Plus, this helps me prove out that all the other GitOps type stuff I'm trying to do
works and sneaky state mutations haven't been added in.


# Wipe the nodes

The first part is pretty straightforward, I just knock out all my nodes and put them back in
maintenance. `--graceful=false` because the last node won't be able to leave the cluster
operable and that's fine. `--reboot` so it comes back up instead of shutting down
(which I guess is default behaviour?)

```bash
talosctl reset --system-labels-to-wipe EPHEMERAL,STATE --reboot --graceful=false --wait=false -n 192.168.40.11;
talosctl reset --system-labels-to-wipe EPHEMERAL,STATE --reboot --graceful=false --wait=false -n 192.168.40.7;
talosctl reset --system-labels-to-wipe EPHEMERAL,STATE --reboot --graceful=false --wait=false -n 192.168.40.9;
```

Ok that's got them all wiped, make sure they're back up in insecure mode:
```bash
talosctl get disks --insecure -n 192.168.40.11;
talosctl get disks --insecure -n 192.168.40.9;
talosctl get disks --insecure -n 192.168.40.7;
```

# Reinstall talos

Use talhelper to generate the apply command with the insecure flag and run it:
```bash
talhelper gencommand apply --extra-flags --insecure
talosctl apply-config --talosconfig=./clusterconfig/talosconfig --nodes=192.168.40.11 --file=./clusterconfig/dk8s-d-hpp-1-lab.yaml --insecure;
talosctl apply-config --talosconfig=./clusterconfig/talosconfig --nodes=192.168.40.7 --file=./clusterconfig/dk8s-d-hpp-2-lab.yaml --insecure;
talosctl apply-config --talosconfig=./clusterconfig/talosconfig --nodes=192.168.40.9 --file=./clusterconfig/dk8s-d-hpp-3-lab.yaml --insecure;
```

Check the dashboard on all nodes and make sure they're up and ready for bootstrapping. All nodes are showing they're in the "Booting" stage, I see 3 nodes listed in the cluster, and messages in the logs about waiting for `etcd` to be available.
Let's bootstrap:

```bash
talosctl bootstrap -n 192.168.40.7 -e 192.168.40.7
```

# Bootstrap scripts

Ok, cluster still won't be in a ready state until I get cilium
installed:

```bash
./cilium.sh
```

I've got the details of how that works in my earlier post on installing cilium.


Wait a bit and then make sure everyone is up and healthy:

```bash
❯ kubectl get nodes -o wide
NAME          STATUS   ROLES           AGE     VERSION   INTERNAL-IP     EXTERNAL-IP   OS-IMAGE         KERNEL-VERSION   CONTAINER-RUNTIME
d-hpp-1-lab   Ready    control-plane   2m49s   v1.32.3   192.168.40.11   <none>        Talos (v1.9.5)   6.12.18-talos    containerd://2.0.3
d-hpp-2-lab   Ready    control-plane   2m47s   v1.32.3   192.168.40.7    <none>        Talos (v1.9.5)   6.12.18-talos    containerd://2.0.3
d-hpp-3-lab   Ready    control-plane   2m48s   v1.32.3   192.168.40.9    <none>        Talos (v1.9.5)   6.12.18-talos    containerd://2.0.3
```

Perfect, now for the rest of my bootstrapping.

Over in my bootstrap folder I first need to make sure I've got my bitwarden secrets available:

```bash
export BWS_ACCESS_TOKEN=<my access token>
```

Then bootstrap `cert-manager` with my `certmanager.sh` script.

Next up we do `external-secrets` with its bootstrap script.

Got an error that may or may not be a problem?

```bash
Error from server (InternalError): error when creating "STDIN": Internal error occurred: failed calling webhook "validate.clustersecretstore.external-secrets.io": failed to call webhook: Post "https://external-secrets-webhook.external-secrets.svc:443/validate-external-secrets-io-v1beta1-clustersecretstore?timeout=5s": dial tcp 10.101.71.86:443: connect: operation not permitted
```

I've wiped the cluster a few times while testing, this does appear to be a timing thing. I have to wait a bit
for some of the installs to finish before the last part that actually creates external secrets works. Running the script
a second time fixes it. Not ideal but not terrible.

Let's do argocd now with the bootstrap script.

and grab my updated argo admin password:

```bash
argocd admin initial-password -n argocd
```

Give it a few minutes to spin up all the cluster resources I'll need to access it and try logging in, and we're up!

About 20 minutes and a nice fresh kubernetes cluster with all my apps and only a handful of commands. Not bad.

One thing to remind myself (and others) of here is that the actual bootstrapping takes
a fair bit longer than just running the commands. Give the system a little
time in between commands and if services don't come up right away just wait a few
minutes before freaking out and diving into troubleshooting.
