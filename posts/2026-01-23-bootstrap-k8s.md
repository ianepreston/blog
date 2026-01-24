---
title: "My first k8s build log - Bootstrapping"
date: "2026-01-23"
description: "I have kubernetes, now what?"
layout: "post"
toc: true
categories: [kubernetes, talos]
---

# Introduction

Continuing my rebooted cluster setup series, let's talk about how I get from
talos and basic kubernetes to a functional cluster.

Now that [I've set up talos](./2026-01-23-talos.md) I have a cluster that's
running kubernetes, but it's not ready for workloads. For one thing, because
talos doesn't ship with
[cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium), I
need to install a [cni](https://github.com/containernetworking/cni). In addition
to that, since I want to do everything the GitOps way, I need to get my cluster
to a state where it can automatically reconcile its state with a git repository.

In short, I need:

- any
  [CRDs](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
  that my manifests for those apps are going to reference but won't be available
  until later.
- [cilium](https://cilium.io/)
- [cert-manager](https://cert-manager.io/)
- [external-secrets](https://external-secrets.io/latest/)
- [flux](https://fluxcd.io/)

# Task overview

As discussed in [previous](./2026-01-23-cluster-env.md)
[posts](./2026-01-23-talos.md), I like to use `Taskfiles` to orchestrate things
like bootstrapping. I have a top line task under my bootstrap `Taskfile` called
`k8s` that kicks off several subtasks. I usually keep them hidden to avoid
cluttering up my task menu, but I can just comment out the `internal: true` line
if I want to call a subtask when troubleshooting. Within
[the file](https://github.com/ianepreston/homelab/blob/166ed3623a07bf1012f582569db4da73b4d9a73c/taskfiles/bootstrap/Taskfile.yaml),
I first create namespaces that resources are going to have to go into, create
namespaces to contain my CRDs and other resources, install CRDs, and install my
required apps along with some key resources they need to be ready to take over
the rest of the operation.

# Task details

## Namespace creation

This task is pretty straightforward. I have a
[manifest](https://github.com/ianepreston/homelab/blob/166ed3623a07bf1012f582569db4da73b4d9a73c/bootstrap/namespace.yaml)
with the name of the namespaces I'm going to install apps or CRDs into. There's
no versioning or configuration on this so I don't bother linking into the actual
manifests that flux will manage, just `kubectl apply` the file.

## Install CRDs

This one is a little trickier. I want to be sure I'm installing the CRDs from
the same version of the apps that I'll be running in the cluster, so I have to
do some parsing. First I make an empty json file in a temporary directory. Next
I loop through the list of apps that I want to install CRDs for, and find their
`OCIRepository.yaml` manifest (here's
[cert-manager](https://github.com/ianepreston/homelab/blob/1b269498dc0ad90cbd2bbdd237e6932b7690bdba/k8s/apps/cert-manager/dev/ocirepository.yaml)
for example). Next I use `yq` to parse out the version number from that
manifest. Then I use `jq` to write out key value pairs for the app name and
version to the temp file. From there I use `minijinja` to template those
versions into a
[helmfile](https://github.com/ianepreston/homelab/blob/166ed3623a07bf1012f582569db4da73b4d9a73c/bootstrap/helmfile-crds.yaml.j2)
and apply the resulting output to install the CRDs for the correct versions of
those apps into the cluster.

## Install apps

The next part installs apps and their required manifests. I do the same trick of
reading in versions from the `ocirepository.yaml` that I did with the CRDs, but
instead of jinja this time I use
[a go template](https://github.com/ianepreston/homelab/blob/537a6a176d4dc9590798789e9becd3d7a13514d2/bootstrap/version.txt.gotmpl)
to pull in the version info. I can't remember why I did it this way for the apps
and the other for the CRDs. Probably just adapting what someone else built, if
there was a better reason I don't remember now. Anyway, that template fills in
values in another
[helmfile](https://github.com/ianepreston/homelab/blob/55900ac31bbb2643b90e3131c8af7f9601711810/bootstrap/apps.yaml)

For each app it installs the app using helm and the values from my
`helmrelease.yaml` file for that app. For apps that need extra steps beyond just
installation it also calls hooks. For example `cert-manager` has this block:

```yaml
needs: ["kube-system/cilium"]
hooks:
  - events: ["postsync"]
    showlogs: true
    command: bash
    args:
      - -lc
      - |-
        #Wait for core CRDs to exist before applying
        until kubectl  get crd clusterissuers.cert-manager.io issuers.cert-manager.io certificates.cert-manager.io &>/dev/null; do
          echo "waiting for cert-manager CRDs..."; sleep 5
        done
        # Apply bitwarden self-signed cert
        kubectl  apply -f {{ requiredEnv "CLUSTER_APPS" }}/external-secrets-config/base/bitwarden-self-signed-cert.yaml
        # Wait for bitwarden-css-certs to exist
        for i in {1..60}; do
          if kubectl  -n external-secrets get secret bitwarden-css-certs &>/dev/null; then
            echo "CA secret bitwarden-css-certs is present."; break
          fi
          echo "Waiting for CA secret bitwarden-css-certs..."; sleep 5
        done
```

which tells it to run after cilium is ready, and then once cert-manager is
installed to wait until its CRDs are available, then install a self-signed cert
that external-secrets will need to set itself up.

The last app to bootstrap is the flux operator. Once it's installed I apply an
external secret with my GitHub authentication so it will be able to access the
bootstrap repo and a `flux-instance` manifest to kick things off.

From there the cluster shouldn't need my direct input and everything will be
applied and managed by making changes in git and having flux pick them up.
