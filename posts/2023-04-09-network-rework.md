---
title: "Redesigning my network"
date: '2023-04-09'
description: "Networking is hard."
layout: post
toc: true
categories: [networking, Linux]
---

# Introduction

Now that [I have basic connectivity](2023-04-08-managed-switch.md) for my managed switch
I need to figure out what I actually want my network to look like, and how I want to make
it look that way.

# Basic goals

Right now my network is completely flat and open, which means that the wifi leak sensor
I've got that's running who knows what firmware can reach the management interface on my
router, or any of the internal servers I'm running. The same is true for guests on my wifi,
or the couple friends I've created VPN credentials for so they can access some of the
services I run. Just typing that actually stresses me out a bit.

The main goal is enhanced security and reliability through network segmentation. Guests
connected to my WiFi shouldn't be able to connect to IoT devices or management interfaces
in my house for example.

A bonus goal is increased performance. My NAS has 4 rj45 ports that support
[link aggregation](https://en.wikipedia.org/wiki/Link_aggregation), and so does the
box that's running my pfsense router. While link aggregation can't boost the speed of
a single connection, and I don't do a ton of concurrent work on my network, having this
would still be nice. Credit to [this post](https://forum.netgate.com/topic/165219/same-vlan-on-multiple-interfaces/6)
for making me realize I should be using link aggregation with the router rather than
trying to split VLANs between multiple separately managed interfaces.

# Hardware I'm working with

My network starts with my router, a QOTOM Q330G4 with 4 1Gb Intel rj45 ports running pfsense.
Next is my recently acquired HP procurve 2810 with layer 3 management and 48 1Gb ports.
Finally for the network stack I have 2 Unifi AP AC-Lite WAPs that support multiple
SSIDs with VLAN tagging. I think that will cover my requirements but there's only one
way to find out for sure.

# What networks I need

## List all the types of devices I have and their usage considerations

To think about what networks I need I have to consider what sorts of things I have on
my network and how I'd like to organize them.

To start, I have the management interfaces for my networking devices. The router at least
won't be on its own network, I'll just have to lock that down with firewall rules. I'm
not entirely clear how locking down the management interface on the switch works, I could
probably put that on its own VLAN, but maybe that's overkill. Right now my unifi controller
is running on the same server that's running all my other services, so I can't isolate it
with VLANs, that will also be firewall rules I guess.

Next there's my servers and homelab. Currently there's my three node proxmox cluster as
well as a standalone box that's running my services until I get things figured out on
the proxmox cluster, but eventually that will be consolidated physically into one big
cluster. Eventually within those physical servers there might be VMs representing different
environments (dev/prod) that I might want to isolate. I'm pretty sure I can apply VLAN
tags to VM interfaces, will have to test that to be sure.

I've got my work laptop, which should really be isolated from everything else. It's
got a wired connection so at least I won't have to make an SSID just for it.

I've got IoT devices, although that's a bit of a hand wavy category. The wifi leak sensor
I previously mentioned doesn't have to talk to anything else in my house so I can safely
isolate it. My phone might be considered an IoT device, but I want it to at least be able
to talk to my NAS so it can do photo backups. My Kobo probably counts as an IoT device,
but there's an ebook service that I run that I'd want it to connect to. This will
require some thought and maybe some firewall rules on top of just network segmentation
I think.

I've got trusted devices for admin like my workstation and my laptop. Those can probably
just go on the same network as my lab and servers.

I've got my partner's trusted devices like her laptop. At this point I'm not sure if
she needs elevated privileges compared to house guests, but it also feels a bit weird
putting her on a guest network in her own house.

Speaking of which, we've got the phones and laptops of any guests that visit us. Generally
I think they just need internet access and can be isolated from IoT and server stuff.

I've mentioned it in a few other places, but I also have my NAS. I'd like to block most
networks from accessing its management interface, but several of them will have to access
its file share, and it also has my photo service running on it.

The last piece is the virtual networks for VPNs. I have OpenVPN running to connect
to an off site Synology NAS that's my off site backup. For everything else I use
wireguard, although right now there's just one tunnel both for myself for administration
and trusted friends that I want to access my services. I'll have to split those out.

## Initial network idea

I'll probably end up changing this, and I'll definitely start with a subset of them
while I'm testing, but let's get the idea down.

### Infra VLAN

This will have the management interface for my switch, my proxmox nodes, my NAS, and
any VMs or physical servers running production services. I think I'll also put my
workstation on this VLAN to make administering things easier. I'll either have an
SSID that's attached to this network or have a wireguard tunnel that can connect to it.
If I can make the wireguard tunnel work internally and externally I'll go with that.

### Sandbox VLAN

This will only be used by VMs in my proxmox cluster. This is less for security than for
testing out services in an isolated environment that might conflict with production services.
It might also be a good place to test out firewall rules or other capabilities without
impacting services.

### Trusted devices VLAN

This will be for devices my partner or I own that we want to be able to access internal
services. Laptops, phones, streaming boxes etc. If I want to limit the services some
devices can access I'll do it with firewall rules.

### Guest devices VLAN

This will be for IoT stuff in the house and guests. It should just be able to access
the internet and I could even experiment with rules that don't let devices on this
network talk to each other, just for added security. I think for now at least I'll put
my work machine on this network as well, especially if I can get device isolation within
this VLAN.

### Infra wireguard tunnel

A wireguard tunnel for me to use to administer my network.

### Trusted guests wireguard tunnel

A wireguard tunnel for guests I've granted access to specific services. Exact services
can be set with firewall rules and similar to guest devices VLAN I can restrict within
network communication (I think).

### Offsite OpenVPN

OpenVPN connection to my offsite backup. Should only be able to communicate with my NAS
in the infra VLAN.

### Trusted devices SSID

WiFi connection for the trusted devices VLAN

### Guest devices SSID

WiFi connection for the guest devices VLAN.

### Summary

So that's four VLANs, two of which require SSIDs for WiFi, plus two wireguard tunnels and
an OpenVPN tunnel.
Compared to my current network of one LAN with one associated SSID, one wireguard tunnel,
and one OpenVPN tunnel. Definitely more complex, but at least right at this moment this
doesn't feel like complete hubris.