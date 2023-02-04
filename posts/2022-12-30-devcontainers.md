---
aliases:
- /configuration/linux/2022/12/30/devcontainers
categories:
- configuration
- linux
date: '2022-12-30'
description: Sure I could just use the Microsoft built ones, but where's the fun in
  that?
layout: post
title: Building my own devcontainers
toc: true

---

# Introduction

Microsoft has created the [devcontainer](https://code.visualstudio.com/docs/devcontainers/containers)
standard for packaging up your development environment into a docker image and I love it.

Even though I have a fairly automated environment setup at home, it's still a hassle
whenever I want to start a new project or pick up an old one to make sure I have all
the dependencies in place. It's even trickier if I'm trying to help another person contribute
to a project of mine. Devcontainers solve both these issues. Microsoft publishes a number of
out of the box images and templates in their GitHub [devcontainers project](https://github.com/devcontainers).

These work quite well, but I'm picky and want things set up in a certain way. For instance,
I want [rcm](https://github.com/thoughtbot/rcm) installed for dotfile management, and
[starship prompt](https://starship.rs/) in any environment I work in. On top of that,
for python development I like the [hypermodern](https://cjolowicz.github.io/posts/hypermodern-python-01-setup/)
suite of tools to be installed. It would be relatively easy to make a dockerfile that
has these features installed and put it in every project, but I want to overengineer things.
This isn't entirely just me liking to hack on things. The build time for my python environment
is actually quite long thanks to compiling several different versions of python, so while a Dockerfile
would work, it would be annoying to maintain and take quite a while to build.

In light of this, I decided to make my own copy of the [images repository](https://github.com/devcontainers/images)
that Microsoft uses to build their devcontainers and make my own. This post chronicles some of the
challenges I had doing that.

# Figuring out the code

To start I just copied the entire [images](https://github.com/devcontainers/images)
repository and poked around. It's a beast of a repo (at least compared to the personal
or small organization projects I'm used to working on) so it took quite a while just to
get a sense of what was there. At a high level there's a `.github` folder which contains
the CI/CD workflows, a `build` folder that contains node scripts that build the images,
and a `src` folder that contains the devcontainer specs. I started by deleting all but
the `base-ubuntu` image from `src` so I could focus on getting one container built without
extensive build times. After that I tried to get the build script working locally. Fortunately
there are pretty good README files included in each section of the codebase, so I could get
a general sense of what was going on.

The next two difficult parts that went together were figuring out how to navigate and
understand the node codebase, since I've never written node or any javascript before, and
figuring out what I'd need to modify to get things working in my repository. Some things
were relatively straightforward, like the GitHub actions were calling for secrets like
`REPOSITORY_NAME` and `REPOSITORY_SECRET` that I'd have to swap out for my image registry
name and credentials. Once I got past that surface level understanding though, it got
trickier. One fairly easy example was that the original GitHub action wanted to be run
on some custom Microsoft `devcontainer-image-builder-ubuntu` VM that I didn't have access
to. It seemed to work fine if I changed that to `ubuntu-latest`, I just had to notice the
issue and change it. Other things were more embedded. Microsoft is publishing their
images to [Azure container registry](https://azure.microsoft.com/en-us/products/container-registry/)
whereas I want to use [Docker hub](https://hub.docker.com/). Again, some of this was
as simple as switching out `az login` with `docker login` in the scripts, but some of
it was a little more complicated. Part of the node code queries the registry to see
what images are there and what tags they have to make sure published image tags aren't
overwritten accidentally. This is a great feature, but it relied heavily on calling the
`acr` command prompt to retrieve that info. I had to find those sections in the code,
figure out what sort of data they'd be returning, figure out what request to send to the
docker hub API to get similar data, and then modify the node code to parse it the same way.
Since I'd never worked with the docker hub API, or node, or seen the actual output of the
`acr` commands I was trying to reproduce, this took some trial and error.

An additional challenge was separating out the nice features of the Microsoft code base
from the stuff that I didn't want and that just made things more complicated. The two
main things in the latter category were the secondary registry logic and the stubs
repository logic. In both cases, Microsoft is publishing lots of extra stuff besides
the built devcontainer image, either because they have two repositories to publish to
(I think this relates to them moving the devcontainer spec outside of VS Code into its
own project) or they want to publish stub files that other developers can extend for their
own purposes. Neither applies to me, but since that logic is embedded in the GitHub actions
and the node code that publishes regular images I had to find and strip out all that
logic before I could publish my own images.

# Building my own devcontainers

Prior to going to all the trouble of setting up this build infrastructure, I'd already
spent quite a bit of time building devcontainer images, primarily for python. In light
of that, once I got the build infrastructure going it wasn't a huge leap to get my own
devcontainers building. There were some growing pains though. The Microsoft image
builder builds multiple variants of images, namely basing them off different Ubuntu
releases or architectures (x86/64 vs arm). I definitely ran into situations where things
seemed to be building fine but then I realized some combo of release and architecture was
failing and stopping the whole pipeline from completing. There are ways to test those things
locally in the repository, but I didn't have any comprehensive workflow set up so it was
easy to miss things. Some stuff I just didn't bother fixing and removed the troublesome
build. For instance, there were a fair number of issues building images based on Ubuntu
18.04LTS (one of the default variants from Microsoft) and I just decided there was no point
spending time fixing issues with a release that was about to be EOL from Ubuntu and
just dropped it. Similarly, my Infrastructure as Code image didn't want to install
Terraform on the arm build. I'm not currently planning to run that on an arm system so
I just dropped it, maybe I'll put it back later if I want to run it off a raspberry pi
but for now it's not worth the effort.

# Conclusion

This was quite likely more effort than it was objectively worth compared to just
building an image and pushing it manually with some tags using the [devcontainer cli](https://containers.dev/supporting#devcontainer-cli)
at least for my personal projects.
I did learn a fair bit going through the exercise though, and since I also intend to
adopt devcontainers at work (for myself and other people writing at least python code)
knowing how to build images in a more automated and versioned manner will be useful.

My repository is [here](https://github.com/ianepreston/devcontainers), the original
Microsoft one is [here](https://github.com/devcontainers/images). My repo is definitely
a bit of a mess with ugly commits just testing out CI/CD outcomes and a lot of failed
releases since I'd never used GitHub directly to release software before, but that's
all part of the learning experience.