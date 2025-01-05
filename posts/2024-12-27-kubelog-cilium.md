---
title: "My first k8s build log - Cilium"
date: "2024-12-27"
description: "Maybe a newbie perspective will be helpful"
layout: "post"
toc: true
categories: [cilium, kubernetes, talos]
---

# Introduction

I'm building out my first kubernetes cluster and in these posts
I'm going to do a relatively raw write up on what I've done to get
it working. These are definitely not authoritative guides, but I think
sometimes having someone who's new write up what they're doing can be
helpful. Hopefully it's useful to others, or at least me when I need to
go back and figure out what I did.

In this inaugural post I'm going to talk about setting up [cilium](https://cilium.io/)
as my [CNI](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/).

## Update

I went back and set this up so that [argocd](https://argo-cd.readthedocs.io/en/stable/)
can take over managing cilium once it's loaded up. The main components
are the same but the structure of some files is slightly different.

This post has been updated to reflect that.

# Background on my setup

For this project I started with a Talos Linux cluster of 3 nodes running
[flannel](https://github.com/flannel-io/flannel). I got interested in
cilium because it allows for more complicated network policies that I thought
I'd want in the future, it has a built in load balancer option so I wouldn't
have to bring in [metallb](https://metallb.io/), and finally in looking at
a bunch of example homelab repos it seems to be what everyone else is
using and they probably have a good reason. PS, no disrespect to metallb,
it worked great when I tested it out, I just figure having that capability
combined and managed with the rest of my network stack will make my life
easier in the future.

Additionally, while this isn't implemented yet, I want to use
[argocd](https://argo-cd.readthedocs.io/en/stable/) to manage
my cluster, so I don't want my cilium install to be too tightly
coupled with talos.

# Initial research

The obvious place to start is the [talos docs](https://www.talos.dev/v1.9/kubernetes-guides/network/deploying-cilium/).
Unfortunately, unlike flannel I can't just set `cilium` as my CNI in my config and have it stood
up when I bootstrap the cluster. Fortunately they give a bunch of options for using cilium.

Since the docs recommend not using the cilium CLI I skipped those options and reviewed
the options available through [helm](https://helm.sh/).

[Method 1](https://www.talos.dev/v1.9/kubernetes-guides/network/deploying-cilium/#method-1-helm-install),
just running the regular `helm install` command after bootstrapping your cluster
but before it reboots because it has no CNI was definitely the most straightforward, but
it felt a bit hacky.
It ended up being what I did, but not before trying and failing with some other options.

[Method 4](https://www.talos.dev/v1.9/kubernetes-guides/network/deploying-cilium/#method-4-helm-manifests-inline-install)
is more elegant, adding in the full templated manifest to your patch, but it had a few
killer drawbacks for my requirements. First, I'd have sensitive information in the templated
manifest, which means I couldn't just dump it in git. I could maybe get around that with
SOPs, but it's extra steps. More importantly, talos would revert any changes to objects
created by the manifest whenever a node rebooted. This means if I patched cilium after
install it would only last until a node reboot. I'd instead have to update my template and
reapply my talos config. That ruled it out.

[Method 5](https://www.talos.dev/v1.9/kubernetes-guides/network/deploying-cilium/#method-5-using-a-job),
defining a job to run in the manifest which would run the cilium installer
seemed great. No timing issues with running commands after cluster bootstrapping, and since it's
only the job object itself directly implemented by talos I should be able to manage cilium
outside it after the setup.

# First issue

Using the approach from Method 5 I added a file to my patches folder with the CNI configs
and the job manifest as specified. After applying the patch to my control plane
nodes I checked the state:

```bash
❯ kubectl get pods -n kube-system
NAME                                  READY   STATUS                       RESTARTS     AGE
cilium-install-chtmv                  0/1     ContainerCreating            0            13s
coredns-64b67fc8fd-l7k7j              1/1     Running                      0            69d
coredns-64b67fc8fd-nlg55              1/1     Running                      0            69d
kube-apiserver-d-hpp-1-lab            0/1     ContainerCreating            0            69d
kube-apiserver-d-hpp-2-lab            1/1     Running                      0            1s
kube-apiserver-d-hpp-3-lab            1/1     Running                      0            9s
kube-controller-manager-d-hpp-1-lab   0/1     ContainerCreating            0            69d
kube-controller-manager-d-hpp-2-lab   0/1     Running                      0            2s
kube-controller-manager-d-hpp-3-lab   1/1     Running                      0            8s
kube-flannel-fzrqv                    0/1     CreateContainerConfigError   0            69d
kube-flannel-kwl77                    1/1     Running                      1 (1s ago)   69d
kube-flannel-rj7m7                    0/1     CreateContainerConfigError   0            69d
kube-proxy-4dtr8                      0/1     CreateContainerConfigError   0            69d
kube-proxy-5s9zh                      1/1     Running                      1 (2s ago)   69d
kube-proxy-9lf9b                      0/1     CreateContainerConfigError   0            69d
kube-scheduler-d-hpp-1-lab            0/1     ContainerCreating            0            69d
kube-scheduler-d-hpp-2-lab            0/1     Running                      0            1s
kube-scheduler-d-hpp-3-lab            1/1     Running                      0            9s
metrics-server-d5865ff47-nb7fp        0/1     CreateContainerConfigError   0            28d
```

Not ideal. After a little while `cilium-install` is in `CrashLoopBackOff`. Also, I still have
flannel pods running.

## The solution

Fortunately this cluster was in the very early stages of testing so I just wiped everything
and did a fresh install. Maybe there's a cleaner way to handle that but it wasn't
really worth it for what I'd set up on the cluster so far. All I'd really done to date
was work through the chapters of [kubernetes up and running](https://www.oreilly.com/library/view/kubernetes-up-and/9781098110192/)

# Second issue

For whatever reason, the job install just wasn't working for me.
I don't have amazing logs from the attempt but the one I wrote down was
this:

```bash
❯ kubectl logs -n kube-system cilium-install-chtmv

Error: Unable to install Cilium: failed parsing --set data: key "KILL" has no value (cannot end with ,)
```

I'm really not sure why that happened, google and ChatGPT both failed me.

## The solution

I just did the helm install approach.

From a fresh set of machines in maintenance mode I just ran:

```bash
talosctl apply -f rendered/controlplane.yaml -n 192.168.40.7 --insecure
talosctl apply -f rendered/controlplane.yaml -n 192.168.40.9 --insecure
talosctl apply -f rendered/controlplane.yaml -n 192.168.40.11 --insecure
# wait until the dashboard starts showing that its waiting on etcd
talosctl dashboard -n 192.168.40.9
# This is helpful too, should show all systems
talosctl get members -n 192.168.40.11
# Start the bootstrap
talosctl bootstrap -n 192.168.40.11
# install cilium
./cilium.sh
```

Where `cilium.sh` is:

```bash
#!/bin/env bash
echo "Installing cilium"
CILIUM_CHART=$(cat ../../k8s/dev/services/cilium/chart/Chart.yaml)
CILIUM_REPO=$(echo "$CILIUM_CHART" | yq eval '.dependencies[0].repository' -)
CILIUM_VERSION=$(echo "$CILIUM_CHART" | yq eval '.dependencies[0].version')
echo "cilium repo: $CILIUM_REPO"
echo "cilium version: $CILIUM_VERSION"
helm repo add cilium $CILIUM_REPO
cat ../../k8s/dev/services/cilium/chart/values.yaml | yq '.["cilium"]' |\
  helm install cilium \
    cilium/cilium \
    --version $CILIUM_VERSION \
    --namespace kube-system \
    --values -
```

Why that version of it allows me to set the capabilities and the job approach
didn't is beyond me at this point.

The actual specification of the version of cilium to install and
the extra parameters to pass to the helm install
are in a separate folder where they can be managed by argo once
the cluster is started. The chart part looks like this:

```yaml
dependencies:
  - name: cilium
    version: "1.16.5"
    repository: https://helm.cilium.io/
```

And the values file looks like this:

```yaml
cilium:
  ipam:
    mode: kubernetes
  kubeProxyReplacement: true
  securityContext:
    capabilities:
      ciliumAgent:
        - "CHOWN"
        - "KILL"
        - "NET_ADMIN"
        - "NET_RAW"
        - "IPC_LOCK"
        - "SYS_ADMIN"
        - "SYS_RESOURCE"
        - "DAC_OVERRIDE"
        - "FOWNER"
        - "SETGID"
        - "SETUID"
      cleanCiliumState:
        - "NET_ADMIN"
        - "SYS_ADMIN"
        - "SYS_RESOURCE"
  cgroup:
    autoMount:
      enabled: false
    hostRoot: "/sys/fs/cgroup/"
  k8sServiceHost: localhost
  k8sServicePort: 7445
```

Same content, but now if I need to do patches or update other
configuration in the future it will be handled by argo, and if I
bootstrap a fresh cluster it will also pick up the latest versions.

# Conclusion

I did finally get cilium working on my cluster and so far haven't
encountered any additional issues. We'll see how it goes when I get around
to managing things with argo. I'd love to know why the job install
approach didn't work and I'd also like to know if there's a clean,
practical way to swap out your CNI on a live cluster. But I've got
a ton of other things to learn about and set up on this cluster and
I had to cut my losses somewhere. I don't think the approach I have
is awful. As a future enhancement maybe I'll have my `cilium.sh`
script parse out what version of cilium I'm managing in argo
so I don't bootstrap clusters with an old version or have to manage
patching versions in two places. That's a bit overengineered for how
often I think I'm going to bootstrap clusters though so maybe I won't

*Edit* I did it anyway, it follows the same pattern as the other
stuff I bootstrap in my cluster so it wasn't a big deal. Besides
some dumb issues like figuring out how to correctly format the
yaml for values and accidentally installing it into the `argocd`
rather than `kube-system` namespace (oops) there were no problems
getting this going in argo.

