---
title: "My first k8s build log - Argocd"
date: "2025-01-04"
description: "Maybe a newbie perspective will be helpful"
layout: "post"
toc: true
categories: [argocd, kubernetes, talos]
---

# Introduction

I'm building out my first kubernetes cluster and in these posts
I'm going to do a relatively raw write up on what I've done to get
it working. These are definitely not authoritative guides, but I think
sometimes having someone who's new write up what they're doing can be
helpful. Hopefully it's useful to others, or at least me when I need to
go back and figure out what I did.

In this post I'll talk about configuring
[argocd](https://argo-cd.readthedocs.io/en/stable/)
and its [vault plugin](https://argocd-vault-plugin.readthedocs.io/en/stable/)
for managing my cluster.

# Initial research

I've been basing a lot of my setup on [acelinkio's](https://github.com/acelinkio/argocd-homelab/tree/main)
repo and took quite a bit of inspiration from there. Definitely the basic idea of
using argo's vault plugin for interpolating secrets into my manifests came from there.

I've also taken some inspiration from [henrywhitaker3's](https://github.com/henrywhitaker3/homelab) repo.

Plus of course the official docs and github pages of argo and the vault plugin, linked in the intro.

# Bootstrapping

With argo in particular the bootstrapping process twists my head a bit,
as I need to install the thing that will manage other things, and ideally
manage itself while it's at it.

I still follow the basic approach as [my bitwarden bootstrapping](2024-12-27-kubelog-bitwarden-secrets.md)
post, with everything I can defined under an app in the services folder to be managed by
argo going forward, with just enough code in the bootstrap directory to get
me over the line.

Starting with the chart I'm following the same general pattern of defining a helm
chart that depends on the upstream app I want to install, so I can drop any additional
manifests I want to manage in the `templates` folder of my local chart.

## Helm Chart

The `Chart.yaml` file is pretty vanilla, the relevant section is as follows:

```yaml
dependencies:
  - name: argo-cd
    version: "7.7.11"
    repository: https://argoproj.github.io/argo-helm
```

Which references the unofficial argo project helm chart.

The `values.yaml` file actually has quite a bit going on as that's where all the custom
config for the vault plugin goes:

```yaml
argo-cd:
  redis-ha:
    enabled: true
  controller:
    replicas: 1
  server:
    replicas: 2
  applicationSet:
    replicas: 2
  configs:
    cmp:
      create: true
      plugins:
        avp-helm:
          discover:
            find:
              command:
                - sh
                - "-c"
                - "find . -name 'Chart.yaml' && find . -name 'values.yaml'"
          generate:
            command:
              - sh
              - "-c"
              - |
                helm template $ARGOCD_APP_NAME --include-crds -n $ARGOCD_APP_NAMESPACE . |
                argocd-vault-plugin generate -
        avp:
          discover:
            find:
              command: 
                - sh
                - "-c"
                - "find . -name '*.yaml' ! -name 'Chart.yaml' ! -name 'values.yaml' | xargs -I {} grep \"<path\\|avp\\.kubernetes\\.io\" {} | grep ."
          generate:
            command:
              - argocd-vault-plugin
              - generate
              - "."

  repoServer:
    rbac:
      - apiGroups: [""]
        resources: ["secrets"]
        verbs: ["get", "watch", "list"]
    replicas: 2
    volumes:
      - name: custom-tools
        emptyDir: {}
      - name: cmp-plugin
        configMap:
          name: argocd-cmp-cm
    volumeMounts:
      - name: custom-tools
        mountPath: /usr/local/bin/argocd-vault-plugin
        subPath: argocd-vault-plugin
    extraContainers:
      - name: avp
        command: [/var/run/argocd/argocd-cmp-server]
        image: quay.io/argoproj/argocd:v2.13.3
        env:
          - name: AVP_TYPE
            value: "kubernetessecret"
        securityContext:
          runAsNonRoot: true
          runAsUser: 999
        volumeMounts:
          - mountPath: /var/run/argocd
            name: var-files
          - mountPath: /home/argocd/cmp-server/plugins
            name: plugins
          - mountPath: /tmp
            name: tmp
          - mountPath: /home/argocd/cmp-server/config/plugin.yaml
            subPath: avp.yaml
            name: cmp-plugin
          - name: custom-tools
            subPath: argocd-vault-plugin
            mountPath: /usr/local/bin/argocd-vault-plugin
    initContainers:
      - name: download-tools
        image: alpine:3.8
        command: [sh, -c]
        env:
          - name: AVP_VERSION
            value: "1.18.1"
        args:
          - >-
            wget -O argocd-vault-plugin
            https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v${AVP_VERSION}/argocd-vault-plugin_${AVP_VERSION}_linux_amd64 &&
            chmod +x argocd-vault-plugin &&
            mv argocd-vault-plugin /custom-tools/
        volumeMounts:
          - mountPath: /custom-tools
            name: custom-tools
```

As mentioned above besides a little bit at the top to configure argo to run in high
availability mode, most of the config is for the vault plugin.
It's basically taking the guide for the
[InitContainer and configuration via sidecar](https://argocd-vault-plugin.readthedocs.io/en/stable/installation/#initcontainer-and-configuration-via-sidecar)
approach for the vault plugin and modifying how it's input so that it will
fit with the helm template. I got a boost for figuring out
how to tie these together from
[this GitHub issue](https://github.com/argoproj/argo-helm/issues/2061). Their
actual problem was an errant `"` but seeing how someone else had done it
helped me figure things out.

I'm setting the `AVP_TYPE` environment variable to `kubernetessecret` because
I'm going to sync secret values themselves into my cluster with the
external-secrets approach previously described, I just want the vault
plugin to be able to interpolate them in in places where you can't
easily just map to a secret object.

Another important part to note is this:

```yaml
    rbac:
      - apiGroups: [""]
        resources: ["secrets"]
        verbs: ["get", "watch", "list"]
```

I didn't see that in the official configs, maybe I missed it,
but it's required to allow the vault plugin to read secrets
in for interpolation.

## Bootstrap script

With that stuff set up we can move back to looking at the bootstrap
script:

```bash
ARGO_CHART=$(cat ../services/argocd/chart/Chart.yaml)
HELM_REPO=$(echo "$ARGO_CHART" | yq eval '.dependencies[0].repository' -)
ARGO_VERSION=$(echo "$ARGO_CHART" | yq eval '.dependencies[0].version')
ARGO_VALS=$(cat ../services/argocd/chart/values.yaml | yq '.["argo-cd"]' - | yq eval 'del(.configs.cm)' -)
ARGO_NAMESPACE=$(cat ../services/argocd/chart/templates/namespace.yaml | yq eval '.metadata.name')
```

As usual the first piece of bootstrapping is reading in the necessary values from the
app spec. Most of this is the same as in previous posts. I'm removing `.configs.cm`
from the bootstrap section mostly at this point because that's how `acelinkio` did
it in theirs. I think the rationale is that it has configuration for external authentication
services and other features that won't be available at the time of bootstrapping, so
we'll have argo sync those things in after once they're actually available.

### GitHub repo

My repo for my homelab is private, which is part of why I don't just link to my
code in these posts. There's nothing super secret in there, but I'm worried
I'll accidentally expose a secret as I'm learning all this new stuff
and keeping it private reduces the blast radius if that happens.

What this means is that I have to pass in secrets to argo so it
can access my repository. Doing it with an ssh key would be fairly
straightforward, but that would grant argo access to all my repos.
Probably not a big deal, but just for kicks I created a GitHub
app key and stored the info in bitwarden to make things a bit
more controlled. This next bit gets the secrets back out of
bitwarden and interpolates them into my repository spec:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  annotations:
    managed-by: argocd.argoproj.io
  labels:
    argocd.argoproj.io/secret-type: repository
  name: argo-repo
  namespace: argocd
stringData:
  type: git
  url: https://github.com/ianepreston/homelab
  githubAppID: "<path:githubkey#argocd-github-app-id>"
  githubAppInstallationID: "<path:githubkey#argocd-github-installation-id>"
  githubAppPrivateKey: |
    <path:githubkey#argocd-github-app-key>
type: Opaque
```

The secrets are formatted like they could be managed by argo but right now
I'm just leaving this manifest in the bootstrap folder and scripting it out.
It's unlikely to change and having the repo be managed by argo while I was
trying to get the vault plugin working caused me a ton of headaches.

```bash
# Get the github info so it can be interpolated into the bootstrap script
GITHUB_INSTALLATION_ID=$(bws secret list | yq '.[] | select(.key == "argocd-github-installation-id") | .value')
echo $GITHUB_INSTALLATION_ID
GITHUB_APP_ID=$(bws secret list | yq '.[] | select(.key == "argocd-github-app-id") | .value')
echo $GITHUB_APP_ID
GITHUB_APP_KEY=$(bws secret list | yq '.[] | select(.key == "argocd-github-app-key") | .value')
echo $GITHUB_APP_KEY
# Install the repo resource with string interpolation
awk -v INSTALLATION_ID="$GITHUB_INSTALLATION_ID" \
    -v APP_KEY="$GITHUB_APP_KEY" \
    -v APP_ID="$GITHUB_APP_ID" '
{
    if ($0 ~ /<path:githubkey#argocd-github-installation-id>/) {
        gsub("<path:githubkey#argocd-github-installation-id>", INSTALLATION_ID)
    }
    if ($0 ~ /<path:githubkey#argocd-github-app-key>/) {
        sub("<path:githubkey#argocd-github-app-key>", "") # Remove placeholder
        print "  githubAppPrivateKey: |" # Add YAML block indicator
        n = split(APP_KEY, lines, "\n") # Split APP_KEY into lines
        for (i = 1; i <= n; i++) {
            print "    " lines[i] # Indent each line
        }
        next # Skip further processing for this line
    }
    if ($0 ~ /<path:githubkey#argocd-github-app-id>/) {
        gsub("<path:githubkey#argocd-github-app-id>", APP_ID)
    }
    print
}' argo-repository.yaml |\
kubectl apply -f -
```

This beast of a script is because the GitHub key is a multi line string and
getting it interpolated into that yaml file with the correct indentation
is tricky. Full credit to ChatGPT for coming up with that monster.

### Install argo

Next up we install argo. I should probably logically have this first in my
script but it works in this order so whatever:

```bash
# Install argo
echo "$ARGO_VALS" |\
  helm template argocd argo-cd \
  --repo $HELM_REPO \
  --version $ARGO_VERSION \
  --namespace $ARGO_NAMESPACE \
  --values - |\
  kubectl apply --namespace $ARGO_NAMESPACE --filename -
```

Note that I'm using `helm template` and piping it to `kubectl apply`
rather than `helm install`. That seems to be the way you need to do it,
I'm honestly not sure why, something about how the chart is designed I imagine.

Finally I just have to add in the resources to spin up my default project
and app of apps:

```bash
kubectl apply -f ../services/argocd/chart/templates/projects.yaml
kubectl apply -f ../services/argocd/chart/templates/apps.yaml
```

Which correspond to these two files:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: cluster
  namespace: argocd
spec:
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  destinations:
  - namespace: '*'
    server: '*'
  sourceRepos:
  - '*'
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster
  namespace: argocd
spec:
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  project: default
  source:
    path: k8s/dev
  repoURL: https://github.com/ianepreston/homelab
    targetRevision: HEAD
    directory:
      recurse: true
      include: "*.app.yaml"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The second one looks in my repo for any yaml files
matching the pattern `*.app.yaml` and applies them.

In each folder for an app I have an `[app-name].app.yaml`
file that contains the app spec for that app,
so once this gets added it will find all my other apps
and apply them.

And with that, after a bit of waiting I have a functional argocd
instance. But right now I can't get to it because I haven't configured
any ingress.

## Accessing it

With argo spun up the first thing I have to do is give myself
a way to access it.

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Port forwards to port 8080 on my local machine
and opening a browser there will bring up the argo login.

To get the password (with port forwarding running)
I can run this in another terminal tab:

```bash
argocd admin initial-password -n argocd
```

From there I can log into the UI, see all my apps (hopefully)
syncing properly and move on to the next stage of setting up my cluster.

# Conclusion

Writing it out now this doesn't seem so bad, but getting argo to bootstrap
itself, especially combined with trying to figure out the vault plugin and
how the helm chart was supposed to work was a huge pain. Hopefully
everything is stable now and I won't really have to worry about this
in the future. On the plus side, going through this I ended up
wiping my cluster a couple times just to make sure there wasn't some
errant config causing issues, which helped me tidy up and increase
confidence in my overall cluster bootstrapping process.
