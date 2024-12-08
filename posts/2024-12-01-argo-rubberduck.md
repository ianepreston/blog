---
title: "Rubber ducking my Argo CD app of apps issue"
date: "2024-12-01"
description: "Update: I fixed it"
layout: "post"
toc: true
categories: [argocd, kubernetes]
---

# Introduction

I've recently been trying to set up [Argo CD](https://argo-cd.readthedocs.io/en/stable/)
in my homelab. I've been banging my head against an issue that I can't seem to solve,
presumably due to some combination of not understanding argo, helm, and/or kubernetes
as well as I need to. Or maybe just some dumb typo.

Anyway, I've been trying to figure this out for a while and despite a lot of
reading of docs, googling, and asking ChatGPT I haven't been able to solve it.
My intent here is to write out the problem in as much detail as I can,
and either figure out the solution directly, or have something to point to
when asking for help.

# The plan

I want to be able to take a cluster from having nothing on it to
all my services with as few commands as possible. I've got the raw
install handled pretty well with [Talos](https://www.talos.dev/),
and the plan is to use Argo for everything on top of Kubernetes.
I've only got one cluster right now, but I'm trying to design
for the future by building this current one as a dev cluster,
and having a production one that I can apply the same setup
to with some config tweaks.

For argo bootstrapping I'm following the app of app patterns
they outline in their [boostrapping guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

To that end I've created an app of apps that right now just
defines one app for [metallb](https://metallb.io/), with
configs for my dev cluster and prod cluster, using different
IP address ranges for each.

# The problem

The problem is that my metallb app isn't picking up
my environment specific configurations, so the address
range is just `null` instead of the IP range I specify.

# The setup

My directory structure looks like this (with a few irrelevant entries removed)

## Directory structure

```
├── argo
│   ├── app-of-apps
│   │   ├── charts
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── apps.yaml
│   │   │   └── _helpers.tpl
│   │   ├── values-dev.yaml
│   │   └── values.yaml
├── services
│   └── metallb
│       ├── charts
│       ├── Chart.yaml
│       ├── templates
│       │   ├── _helpers.tpl
│       │   └── metallb-config.yaml
│       ├── values-dev.yaml
│       └── values.yaml
```

Within the `argo` folder I have my app of apps built using [helm](https://helm.sh/).

## App of apps

### app of apps apps.yaml

The `apps.yaml` looks as follows:

```yaml
{{- range $appName, $app := .Values.apps }}
{{- if $app.enabled }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ $appName }}
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ianepreston/homelab.git
    targetRevision: {{ $.Values.targetBranch }}
    path: {{ $app.path }}
  # Should let apps change sync policy without app of apps resetting it
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: "*"
      kind: "Application"
      namespace: "*"
      jsonPointers:
        - /spec/syncPolicy/automated
        - /metadata/annotations/argocd.argoproj.io~1refresh
        - /operation
{{- if eq $app.type "helm" }}
  helm:
    valueFiles:
      - values.yaml
      - {{ $app.valuesFile }}
{{- end }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ $app.namespace }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
{{- end }}
{{- end }}
```

The idea is to go through my `values.yaml` and for each app that's defined there
create an argo app spec. Right now I've only got the one but this should be extensible.

### app of apps values.yaml

The corresponding `values.yaml` is as follows:

```yaml
targetBranch: main
targetEnv: prod

apps:
  metallb:
    type: helm
    enabled: true
    namespace: metallb-system
    path: k8s/services/metallb
```

### app of apps values-dev.yaml

For the deployment to my dev cluster I also applied the `values-dev.yaml` file in this folder
to override the branch and env settings:

```yaml
targetBranch: dev
targetEnv: dev
```

### Applied app of apps

Running `helm template app-of-apps . --values values.yaml --values-dev.yaml` I can see the app rendering
what I think is correctly:

```yaml
---
# Source: app-of-apps/templates/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ianepreston/homelab.git
    targetRevision: dev
    path: k8s/services/metallb
  # Should let apps change sync policy without app of apps resetting it
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: "*"
      kind: "Application"
      namespace: "*"
      jsonPointers:
        - /spec/syncPolicy/automated
        - /metadata/annotations/argocd.argoproj.io~1refresh
        - /operation
  helm:
    valueFiles:
      - values.yaml
      - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Metallb

Meanwhile, my metallb chart (based on [this umbrella chart](https://github.com/metallb/metallb/issues/2241#issuecomment-1895822116))
looks like this:

### metallb metallb-config.yaml

```yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: {{ .Values.addressPoolName }}
  namespace: metallb-system
spec:
  addresses:
    - {{ .Values.addressRange }}
  avoidBuggyIPs: true

---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: metallb-pfsense-bgppeer
  namespace: metallb-system
spec:
  myASN: {{ .Values.myASN }}
  peerASN: 64501
  peerAddress: {{ .Values.peerAddress }}

---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: metallb-bgpadvertisement
  namespace: metallb-system
```

### metallb values.yaml

```yaml
addressPoolName: metallb-pool
```

### metallb values-dev.yaml

```yaml
addressRange: 192.168.40.20-192.168.40.40
myASN: 64500
peerAddress: 192.168.40.1
```

# Troubleshooting

So somewhere in these definitions Argo is missing where it should
be setting the parameters for `addressRange`, `myASN`, and `peerAddress`.

If I go into my app of apps in the Argo UI and bring up metallb I get
the following desired manifest:

## Metallb app desired manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    app.kubernetes.io/instance: apps
  name: metallb
  namespace: argocd
spec:
  destination:
    namespace: metallb-system
    server: https://kubernetes.default.svc
  helm:
    valueFiles:
      - values.yaml
      - values-dev.yaml
  ignoreDifferences:
    - group: '*'
      jsonPointers:
        - /spec/syncPolicy/automated
        - /metadata/annotations/argocd.argoproj.io~1refresh
        - /operation
      kind: Application
      namespace: '*'
  project: default
  source:
    path: k8s/services/metallb
    repoURL: https://github.com/ianepreston/homelab.git
    targetRevision: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

I can see the `values-dev.yaml` entry there, so the initial templating
from my app of apps appears to have picked up the correct environment
and applied that part directly.

Heading back to the UI and looking directly at the metallb app
and looking at the manifest there's a lot less stuff:

```yaml
project: default
source:
  repoURL: https://github.com/ianepreston/homelab.git
  path: k8s/services/metallb
  targetRevision: dev
destination:
  server: https://kubernetes.default.svc
  namespace: metallb-system
syncPolicy:
  automated:
    prune: true
    selfHeal: true
ignoreDifferences:
  - group: '*'
    kind: Application
    namespace: '*'
    jsonPointers:
      - /spec/syncPolicy/automated
      - /metadata/annotations/argocd.argoproj.io~1refresh
      - /operation
```

I don't know if this is intended behaviour or what.

If I go to the parameters for the metallb app
the only parameter that's set is `addressPoolName`.
It's set as a parameter, which I think makes sense from
my understanding of argo rendering out helm charts
and then managing the rendered manifests rather
than directly working with helm. The part that
doesn't make sense of course is my missing dev
variables.

I've updated the pool name in `variables.yaml` and
it's synced all the way through so some updating is
happening.

I've also changed the order in my apps template
to have `values-dev.yaml` listed first but still
only the value in `values.yaml` shows up in the
downstream app.

I've also rendered the chart locally with
`helm template metallb . --values values.yaml --values values-dev.yaml`
and that correctly applied all the values as I'd expect.

# Conclusion

I'd hoped that writing all this out would help me identify where
I was going wrong, but it hasn't. I'm going to post this
and dump it on some forums and see if anyone can help me.
If they do or I figure it out on my own I'll update this
with the solution.

# Update with a fix

The next thing I tried was deleting my app of apps, templating it out,
and applying it with `kubectl`:

```bash
❯ helm template app-of-apps . --debug --values values.yaml --values values-dev.yaml
install.go:222: [debug] Original chart version: ""
install.go:239: [debug] CHART PATH: /home/ipreston/homelab/k8s/argo/app-of-apps

---
# Source: app-of-apps/templates/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ianepreston/homelab.git
    targetRevision: dev
    path: k8s/services/metallb
  # Should let apps change sync policy without app of apps resetting it
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: "*"
      kind: "Application"
      namespace: "*"
      jsonPointers:
        - /spec/syncPolicy/automated
        - /metadata/annotations/argocd.argoproj.io~1refresh
        - /operation
  helm:
    valueFiles:
      - values.yaml
      - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Applying this led to this error:

```bash
❯ kubectl apply -f metallbtest.yaml
Error from server (BadRequest): error when creating "metallbtest.yaml": Application in version "v1alpha1" cannot be handled as a Application: strict decoding error: unknown field "spec.helm"
```

Which led me to realize that `helm` is supposed to be under `spec.source`, not just `spec`. So it was an indentation error.

I'm sure that error was somewhere in the error log for my app of apps
deploy but I sure didn't see it.

This was super annoying but I learned some valuable lessons
about helm, troubleshooting, and argo, so overall I guess it's a win.
