---
title: "My first k8s build log - Bitwarden Secrets"
date: "2024-12-27"
description: "Maybe a newbie perspective will be helpful"
layout: "post"
toc: true
categories: [bitwarden, kubernetes]
---

# Introduction

I'm building out my first kubernetes cluster and in these posts
I'm going to do a relatively raw write up on what I've done to get
it working. These are definitely not authoritative guides, but I think
sometimes having someone who's new write up what they're doing can be
helpful. Hopefully it's useful to others, or at least me when I need to
go back and figure out what I did.

In this post I'm going to talk about setting up [external secrets](https://external-secrets.io/latest/)
with the [bitwarden secrets manager](https://bitwarden.com/products/secrets-manager/) backend.

# Background on my setup

For this project I started with a Talos Linux cluster of 3 nodes.

Additionally, while this isn't implemented yet, I want to use
[argocd](https://argo-cd.readthedocs.io/en/stable/) to manage
my cluster, but there's a bit of a chicken and egg issue here where
I need to be able to pull in secrets to argo to manage things, so I have to
bootstrap this capability in, preferably in such a way that argo
can easily take over managing it later.

# Initial research

## Figuring out the bitwarden secrets CLI

First I should just figure out how to use the bitwarden secrets
cli. I'll need it to inject the initial access tokens anyway

I grab the access token for the machine account I created
(stored as a secure note in bitwarden for now)
and run `export BWS_ACCESS_TOKEN=[the token]`
from there I can list projects with `bws project list` to show
that I'm authenticated.

I'm also going to add the machine token as a secret
under the key `machinetoken` in the project. I'll still
have to retrieve it for CLI use, but once I have it
I can safely inject it into kubernetes or whatever
using that.

I can also access secrets about the way I'd expect to
for example `bws run 'echo "$testsecret"` this works
to inject a secret into a command.

## Official docs

- [external-secrets bitwarden provider](https://external-secrets.io/latest/provider/bitwarden-secrets-manager/) pretty minimal docs but handy
- [bitwarden SDK certificates docs](https://github.com/external-secrets/bitwarden-sdk-server?tab=readme-ov-file#certificates) external-secrets docs refer to this to configure the self-signed cert to communicate
- [bitwarden SDK hack folder](https://github.com/external-secrets/bitwarden-sdk-server/tree/main/hack) the example files the certificate docs point to

## What about bitwarden secrets operator?

In addition to plugging bitwarden secrets into
external-secrets they also offer their own
operator [here](https://bitwarden.com/help/secrets-manager-kubernetes-operator/).

This is obviously purpose built for bitwarden
as opposed to external-secrets and therefore will
have an easier setup story than external secrets.

I did mess around with it and probably could have made it work
but worried that it would make it harder for me to learn from
other example repositories, as most of the ones I've found use
1password with external-secrets. From my reviewing of the docs
it seems like I'd have to inject a secret for my machine token for
bitwarden in every namespace that I wanted to create bitwarden secrets,
as opposed to external-secrets letting me create one `ClusterSecretStore`
and then just create the secrets I want in each namespace.
There's probably a way around that but for now I'm happy with putting
in more work on initial setup to have a more standard approach going
forward. It's unlikely I'll swap out my secrets manager but this will also
make that easier since external secrets supports many options.

## Helpful example repos

- [alexwaibel secretstore](https://github.com/alexwaibel/home-ops/blob/main/kubernetes/apps/external-secrets/external-secrets/stores/clustersecretstore.yaml) still figuring my way around this code base but actually uses bitwarden secrets so definitely a good example.
- [acelinkio setup docs](https://github.com/acelinkio/argocd-homelab/blob/main/docs/setup.md) good bootstrapping ideas
- [acelinkio external secrets manifest](https://github.com/acelinkio/argocd-homelab/blob/main/manifest/external-secrets.yaml) not super useful to me since it uses 1password but might be handy to refer to 
- [acelinkio 1password connect](https://github.com/acelinkio/argocd-homelab/blob/main/manifest/1passwordconnect.yaml) again not super useful but might have to do some compare and contrast
- [henrywhitaker3 apps](https://github.com/henrywhitaker3/homelab/blob/main/kubernetes/k3s/bootstrap/manifests/root.yaml) not using this for any secrets config but it is how I'm planning to organize my apps so when I build out templates this is handy to have available

## Overview of requirements

The main thing I need is external-secrets installed with the additional options
to load a `bitwarden-sdk` container, which is how external-secrets actually
retrieves secrets from bitwarden. To support that I'll also need a regular
kubernetes secret with the machine access token to connect to bitwarden secrets,
as well as a way of providing TLS certs so that external-secrets and the bitwarden
SDK can talk to each other over https. Finally, just to up the difficulty, I need all
this to be manually applied initially, as it's a prerequisite for setting up my
argo automations, but in such a way that argo can take over managing things once it's
up and running.

# File structure

This wasn't the first thing I actually figured out, but it's important
to understand the rest of what I'm doing in this post so let's start here.

```bash
.
├── bootstrap
│   ├── cert-manager.sh
│   ├── external-secrets.sh
└── services
    ├── certmanager
    │   ├── cert-manager.app.yaml
    │   └── chart
    │       ├── Chart.yaml
    │       ├── templates
    │       └── values.yaml
    └── externalsecrets
        ├── chart
        │   ├── Chart.yaml
        │   ├── templates
        │   │   ├── bitwarden-self-signed-cert.yaml
        │   │   └── external-secret-store.yaml
        │   └── values.yaml
        └── external-secrets.app.yaml
```

The basic idea is that everything under `services` has
the specifications of what state I'd like the app to be in
when my cluster is up and managed by argo, and `bootstrap`
reads in that data along with whatever initial steps I need to get
things started.

For all of these apps I'm following what I think is called an
umbrella chart pattern, where I create a helm chart that specifies
a dependency on some external chart, and then only put manifests under
`templates` that extend that installation with my custom configs.
`cert-manager` at this point is empty but you can get an idea of
how that works by looking at `external-secrets`, I'll go into more
detail on the contents later in the post. Outside the chart folder
I have a `<app-name>.app.yaml` file. This sets the manifest for an
argocd app, which I'll deploy with an app of apps pattern that
looks in these folders for all files matching  the `*.app.yaml`
pattern.

# Installing cert-manager

Installing cert-manager is a necessary pre-requisite to creating
the certificates necessary to have external-secrets working properly,
so we'll start there. 

The first thing to set up is the basic installation of cert-manager.
In `services/cert-manager/chart/Chart.yaml` I specify the external
dependency:

```yaml
dependencies:
  - name: cert-manager
    version: "v1.16.2"
    repository: https://charts.jetstack.io
```

And then in `values.yaml` in the same folder I specify the configuration
for the install. I could provide values to my templates in this file as well
but in this case I don't have to.

```yaml
cert-manager:
  crds:
    enabled: true
    keep: true
  replicaCount: 3
  podDisruptionBudget:
    enabled: true
```

That's it for the general target setup and what I want argo to manage,
now I just have to set up a script that will use that to install
cert-manager in advance of argo taking over.

Up in `bootstrap` I have the script for this:

```bash
#!/bin/env bash
echo "Installing cert-manager"
## Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io --force-update
# Figure out what version of cert-manager to install
export certManagerVersion=$(cat ../services/certmanager/chart/Chart.yaml | yq eval '.dependencies[0].version')
# Grab the values from the app chart for certmanager and install with helm
cat ../services/certmanager/chart/values.yaml | yq '.["cert-manager"]' | \
  helm install cert-manager \
  --create-namespace \
  --namespace cert-manager \
  --version $certManagerVersion \
  jetstack/cert-manager \
  --values -
```

For the most part this is a standard helm install, except in a couple places
I'm using `yq` to read in values from the chart I defined in `services`,
First to extract the version of `cert-manager` to install and then to
pipe in the values from `values.yaml` for cert-manager to the `helm install` command.

I went back and forth a lot over whether I should do the certificate issuers and certificates
for bitwarden-secrets in with cert-manager or external-secrets since you could make a case
for them being associated with either, but in the end I went with external-secrets so
I'll discuss that in the following section.

# Installing external-secrets

This one is where all the fun actually happens.

## helm install

The actual installation of external-secrets follows a very similar pattern
to cert-manager.

In the helm values I put in the arguments I need for the installation:

```yaml
external-secrets:
  installCRDs: true
  bitwarden-sdk-server:
    enabled: true
```

The first bit of the bootstrap script looks much the same as well:

```bash
#!/bin/env bash
echo "Installing External Secrets"
## Add the Helm repository
helm repo add external-secrets https://charts.external-secrets.io --force-update
# Figure out what version of external-secrets to install
export externalsecretsVersion=$(cat ../services/externalsecrets/chart/Chart.yaml | yq eval '.dependencies[0].version')
# Grab the values from the app chart for externalsecrets and install external secrets
cat ../services/externalsecrets/chart/values.yaml | yq '.["external-secrets"]' | \
  helm install external-secrets \
  --create-namespace \
  --namespace external-secrets \
  --version $externalsecretsVersion \
  external-secrets/external-secrets \
  --values -
```

## set up certificates

As discussed above, I need a way for the external-secrets and bitwarden SDK containers
to talk to each other over https. To be honest I don't really understand this part
as well as I'd like and it's mostly cobbled together from the links listed
in the research session.

All these parts are in the `bitwarden-self-signed-cert.yaml` file under the
template for the external-secrets installer but I'll break it out into
individual manifests here for discussion.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: bitwarden-bootstrap-issuer
spec:
  selfSigned: {}
```

As the name suggests this is the first step of bootstrapping trust between
the two containers, creating a certificate issuer which generates
self-signed certificates.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: bitwarden-bootstrap-certificate
  namespace: cert-manager
spec:
  # this is discouraged but required by ios
  commonName: cert-manager-bitwarden-tls
  isCA: true
  secretName: bitwarden-tls-certs
  subject:
    organizations:
      - external-secrets.io
  dnsNames:
    - external-secrets-bitwarden-sdk-server.external-secrets.svc.cluster.local
    - bitwarden-sdk-server.external-secrets.svc.cluster.local
    - localhost
  ipAddresses:
    - 127.0.0.1
    - ::1
  privateKey:
    algorithm: RSA
    encoding: PKCS8
    size: 2048
  issuerRef:
    name: bitwarden-bootstrap-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

Next up we make a certificate that's good for the dns names of both
containers issued by the self signed certificate issuer.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: bitwarden-certificate-issuer
spec:
  ca:
    secretName: bitwarden-tls-certs
```

Now we make another certificate issuer that's signed
by the previously created certificate. This is where my knowledge
really falls down, I'm not sure what this extra step is doing
for me and I'm just cargo-culting it in from the other examples
I've seen.

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: bitwarden-tls-certs
  namespace: external-secrets
spec:
  secretName: bitwarden-tls-certs
  dnsNames:
    - bitwarden-sdk-server.external-secrets.svc.cluster.local
    - external-secrets-bitwarden-sdk-server.external-secrets.svc.cluster.local
    - localhost
  ipAddresses:
    - 127.0.0.1
    - ::1
  privateKey:
    algorithm: RSA
    encoding: PKCS8
    size: 2048
    rotationPolicy: Always
  duration: 168h # 7d
  renewBefore: 24h # 1d
  issuerRef:
    name: bitwarden-certificate-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: bitwarden-css-certs
  namespace: external-secrets
spec:
  secretName: bitwarden-css-certs
  dnsNames:
    - bitwarden-secrets-manager.external-secrets.svc.cluster.local
  privateKey:
    algorithm: RSA
    encoding: PKCS8
    size: 2048
    rotationPolicy: Always
  usages:
    - client auth
  issuerRef:
    name: bitwarden-certificate-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

Finally we make two more certificates issued by the signed issuer,
one for the bitwarden-sdk and one for external secrets. Again, why I
have to do it this way is lost on me for the most part. The one cert
is named `bitwarden-tls-certs` because that's what the installation
of external-secrets is looking for, the other is named `bitwarden-css-certs`
because it's attached to a `ClusterSecretStore` object. Most of the
other specifications are just copy pasted and I didn't really look
into the particulars of why they're set the way they are.

Now that I've created the spec I need to apply it in my bootstrap script,
which is simply done by adding `kubectl apply -f ../services/externalsecrets/chart/templates/bitwarden-self-signed-cert.yaml`
to it.

## Configure the secret store

Next I need to inject a secret to be used by the `ClusterSecretStore` to authenticate
to bitwarden. As discussed above, I've saved the access code for the
machine identity I created for this project to the project so I can
retrieve it with the bitwarden secrets cli:

```bash
bws run 'kubectl create secret generic bitwarden-access-token --namespace bitwarden-secrets --from-literal token="$machinetoken"'
```

Next I want to grab the organization ID and project ID for configuring the secret
store. I'm not totally sure these should be considered sensitive but
decided to err on the side of caution.

```bash
export PROJECT_ID=$(bws project list | jq -r '.[0].id')
export ORGANIZATION_ID=$(bws project list | jq -r '.[0].organizationId')
```

Since I'm authenticating to the bitwarden secrets CLI using the machine ID that
only has access to this one project I can be confident the first project listed
will return the right project and organization IDs.

With these precursors all set up I can set up the manifest for
the `ClusterSecretStore`, which will live in the `services` folder so
it can be managed by argo once bootstrapping is complete:

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: bitwarden-secretsmanager
spec:
  provider:
    bitwardensecretsmanager:
      apiURL: https://api.bitwarden.com
      identityURL: https://identity.bitwarden.com
      auth:
        secretRef:
          credentials:
            key: token
            name: bitwarden-access-token
            namespace: bitwarden-secrets
      bitwardenServerSDKURL: https://bitwarden-sdk-server.external-secrets.svc.cluster.local:9998
      organizationID: <path:bitwardenids#organizationid>
      projectID: <path:bitwardenids#projectid>
      caProvider:
        type: Secret
        name: bitwarden-css-certs
        namespace: external-secrets
        key: ca.crt
```

I'm using a `ClusterSecretStore` because I don't want to have to
recreate all these self-signed certs and `SecretStore` objects
in every namespace that uses secrets.

Note that the `organizationID` and `projectID` keys don't have the
literal IDs. The idea there is that I'm going to eventually
use [argocd vault plugin](https://argocd-vault-plugin.readthedocs.io/en/stable/)
to inject those secrets into the manifests that argo is managing.

For now though I need some way to substitute out those strings
with the actual keys so I can apply the manifest before argo
is up.

```bash
# Create the argo namespace so project id and organization ID can have their string substitution secret added there
kubectl create namespace argocd
# Add the secrets into the namespace
kubectl create secret generic bitwardenids --namespace argocd --from-literal projectid=$PROJECT_ID --from-literal organizationid=$ORGANIZATION_ID
# Parse out the argo vault plugin substitution from the yaml so it can be applied
cat ../services/externalsecrets/chart/templates/external-secret-store.yaml |\
  sed -e "s|<path:bitwardenids#organizationid>|${ORGANIZATION_ID}|g" \
  -e "s|<path:bitwardenids#projectid>|${PROJECT_ID}|g" |\
  kubectl apply -f -
```

I'm not totally sure how argo will handle having that
manually created secret in its namespace that it doesn't
manage, but I'll have a similar issue in the external-secrets
deployment since I manually had to deploy the machine ID secret
there. I'll figure that out when I get to argo. For now with
a bit of `sed` magic I'm substituting the placeholders for
the actual values and applying the secret.

# Testing it out

To do a quick test I made a deployment of
[kuard](https://github.com/kubernetes-up-and-running/kuard)
and injected a test secret in as an environment variable:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: kuard
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: bitwarden-kuard-test
  namespace: kuard
spec:
  refreshInterval: 1h
  secretStoreRef:
    # This name must match the metadata.name in the `SecretStore`
    name: bitwarden-secretsmanager
    kind: ClusterSecretStore
  data:
  - secretKey: test
    remoteRef:
      key: "testsecret"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuard
  namespace: kuard
  labels:
    run: kuard
spec:
  selector:
    matchLabels:
      run: kuard
  replicas: 1
  template:
    metadata:
      labels:
        run: kuard
    spec:
      containers:
      - name: kuard
        image: gcr.io/kuar-demo/kuard-amd64:blue
        env:
            - name: TEST_SECRET
              valueFrom:
                secretKeyRef:
                  name: bitwarden-kuard-test
                  key: test 
```

I added a test secret to bitwarden secrets with a "hello world" value
and then checked the system environment tab on the kuard
deployment to make sure it was showing up there correctly. It was!

# Conclusion

Bootstrapping secrets management really hurt my brain. I spent a lot of time
figuring out which thing was a prerequisite for which other thing and how to
organize all the objects I needed so they'd both make sense to me and
(hopefully) be easy to manage going forward with argocd. 

I think I did ok on both counts but I guess I'll find out in the next stage
when I actually try and bring argo into this.
