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

### Infra LAN

This will have the management interface for my switch, my proxmox nodes, my NAS, and
any VMs or physical servers running production services. I think I'll also put my
workstation on this LAN to make administering things easier. I'll either have an
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

# Clean up pfsense

Before I start moving things around there are a couple of small tweaks I want to make
to my pfsense setup after reviewing [this guide from Lawrence Systems](https://www.youtube.com/watch?v=fsdm5uc_LsU)
in preparation for this move. I'll document them here, but they're not really directly
relevant to what I'm doing, I just want to have them done before I create a bunch of
new networks, as some of them will interact with that.

The first tip I'm going to follow is just to add a third column to my dashboard. This
obviously doesn't relate to the network setup, but it was a great tip and now I can
see more of what's going on at a glance in my pfsense dashboard on my nice wide monitor.

The next one is the thing that made me want to take care of this stuff prior to messing
with my network, and that's to change the default port for the management portal on pfsense.
The guide makes the very good point that if you want your gateway to handle reverse proxy
tasks (which I eventually will for things like load balancing entrypoints to my kubernetes
or proxmox cluster) then having your management interface on the default https port 443
will lead to conflicts. There's a minor security through obscurity advantage to moving it
too, but for me it's about removing conflicts with reverse proxies. Since I'm going to
put firewall rules in place that allow or block access to this management interface on
various networks it will be nice to have the port updated and defined in advance. In the
system, advanced, admin access section I'll set the webConfigurator to use HTTPS on port
`10443`. The redirect works although I'm getting errors about self-signed certs. I've got
a plan for that but it's happening after I get this other stuff sorted.

The one other thing I'm going to do at this point before I get started doesn't come from
the guide, but I'm going to rename a couple of my interfaces. Specifically I'm going to
rename my old LAN interface from `LAN` to `LegacyLAN` and `LabLAN` to just `LAN`. I might
eventually get rid of the LAN interface altogether and add it as another aggregation line
for my new LAN, but for the foreseeable future it's just going to kick around as a fallback
network in case things go bad and I want to go back to a flat network while I figure them
out.

# Look up switch commands

At this point I'm almost ready to actually start setting up the network. The last thing
I want to do is make sure I'm familiar with the commands or processes of configuring this
stuff on pfsense and my switch. For pfsense I'm as comfortable as I can be without having
actually implemented anything. I've watched some guides and read the docs on link aggregation
and VLANs. The switch (as my [last post](2023-04-08-managed-switch.md) demonstrated) is
a lot more of a black box for me at this point. For what I'm trying to do I could probably
use either the menu or cli interface. I know hardcore network folks would be all about
the CLI, but I think I've established that's not who I am, and for this level of complexity
the menu is probably easier. I'd like to know what the commands are as well though just
to have some options. I'll be doing all of this config from a connection on the serial
port of the switch to reduce the odds of locking myself out while I test something.

## Figure out the menu

Getting into the menu interface is easy from the cli, just enter `menu` from the command
prompt. From the menu interface option 5 takes me back to the CLI.
Let's take a look around at the things I'll want to use.

### Status and Counters

Under `Status and Counters` and then `General System information` I get some traffic info,
the MAC address, and the firmware version of the switch (which looks like it's at the
latest version). Under `Switch Management Address Information` I see the management IP
and gateway info I set. I also notice that the time server address isn't set. I should
probably change that since right now the switch thinks it's January 1990. Add that to the
todo list. Under `Port Status` I can see that only the port I've connected to pfsense
is up. All the ports look basically the same except they're a mixture of `MDI` and `MDIX`
for `MDI Mode`. I have no idea what that means. Based on [this post](https://community.fs.com/blog/mdi-vs-mdix-and-auto-mdimdix-basis.html)
it's related to the type of cable wiring you're using. There's also apparently an option
to have it automatically configured. I'll keep this in mind but for now let's assume my
switch defaults to auto configure that and it'll just work, but keep this in mind for
troubleshooting later. `VLAN Address table` is empty but has columns for `MAC address` and
`Located on Port` so that might be handy to come back to later. `Port Address Table` lets
me pick a port and then pulls up a table listing `MAC address`, but it's empty. Leave that
for now.

### Set time server

Hopping over to switch setup I set the Time Sync method to `TIMEP`, the mode to `Manual`
and set the server address as my gateway to use the pfsense time server. Setting that
didn't change the time in the menu. I think maybe I need `SNTP`, which
[according to this](https://forum.netgate.com/topic/143151/does-pfsense-support-sntp/5) is
interoperable with the `NTP` protocol pfsense uses (I don't have an option for `NTP` on
the switch). Setting that up still doesn't seem to be updating the time. Maybe I have
to wait for a refresh? You'd think it would trigger one automatically when you change
the config. How can I test this? Searching around doesn't find anything. Let's not get
too sidetracked. I'll set a timer for 12 minutes (default polling interval is 720 seconds)
and check back on this later.

Coming back after 12 minutes the time is showing up correctly on the switch. Glad I didn't
spend a bunch of time troubleshooting that, although it's silly it doesn't try and sync
after a config change automatically.

### Switch configuration

This is the menu where most of the action will be for me. The first entry `System Information`
is just what you get when you run the `setup` command so I've already been there. It's where
I configure the switch IP, default gateway and time settings (or try to at least).

Under `Port/Trunk Settings` I see that all my ports are set to enabled and `Mode` is set
to `auto`, so that probably means I don't have to worry about that whole `MDI/MDX` thing.
I can also group ports into trunks here, which is probably where I'll need to be to enable
`LACP`. The interface is annoying, I have to hit space to toggle through 24 trunk groups
before I can get back to the default of being empty. I can see why I'd want to use the
CLI if I was going to do this a lot.

`Network Monitoring Port` is disabled and that's probably fine for now. `IP Configuration`
has similar settings to what I did under `System Information` so I don't need to mess
with it.

`SNMP Community Names` is a new thing for me. [Based on this](https://www.netadmintools.com/snmp-community-string)
post I'm just going to leave it alone for now.

#### VLAN Menu

`VLAN Menu` seems like it will be of interest to me, let's see what I can do here.

Under `VLAN Support` I can set the maximum number of VLANs to support. The default of
8 is more than the 3 I currently think I need so let's leave that. Primary VLAN is set
to `DEFAULT_VLAN` which from my preliminary reading should be `VLAN1`. I think that's
all fine, just note it for now. The last piece under here is whether GVRP is enabled, and
by default it isn't. From reading [this](https://www.techtarget.com/searchnetworking/definition/GVRP)
that seems to be what I want so let's move on.

Under `VLAN Names` I've currently only got ID `1` associated with `DEFAULT_VLAN` so
that confirms my suspicion there. I'll come back to this and add `trust`, `guest`, and
`lab` VLANs later. Under `VLAN Port Assignment` I can tag various ports with the VLAN
tags I've created. Again, that will come in handy eventually.

## Figure out the CLI

While it seems like I could do everything I need to do from the menu, let's give me
another option with the CLI.

* Port status: `show interfaces brief` nicely pages through the port status I saw in the
  menu. I think checking that from the menu is nicer since I can scroll up and down easily
  but it's nice that it's there. I can also check specific ports by adding a number, a
  comma separated list of numbers, or a dashed number range to just see a few ports. That
  might be handier.
* Port/Trunk settings: I can use the `show trunks` command to show configured trunks,
  with the option to add a port range for just certain ports. I can also run `show lacp`
  just to see `LACP` configured ports. I should also be able to use `trunk <port-list> < trk1 ... trk24 > < trunk | lacp >`
  to configure a trunk. A nice word of caution at this point, the docs **strongly**
  recommend not having these ports connected when you're configuring this. So I'll have
  to do this over serial with the uplink ports disconnected until both pfsense and the
  switch are configured.
* VLAN stuff: VLAN stuff is apparently not included in my docs. Weird. After grabbing
  the "Advanced traffic management guide" for the switch I'm ready to go. `show vlans`
  lists all the VLANs I have configured, currently just the default one. `show vlan <vlan-id>`
  does what you'd expect. For instance if I do `show vlan 1` all my ports show as
  `untagged` which means untagged packets that they receive will be treated as part of
  vlan1. `vlan <vlan-id> [name <name-str>]` will either create a vlan with the specified
  ID and name, or enter me into the context of that vlan if it already exists. I think
  that's all I actually need to do at this point.

# Set up LACP for uplink

Time for the first stage of implementation. I want to get link aggregation set up to
pfsense before anything else because I have to create the aggregation interfaces in
pfsense from scratch, I can't use an existing interface. Plus I'll have to do this
part with a serial connection. Down in the utility room I hook my laptop up to the serial
port and then bring up the pfsense interface. Might as well do that part first. A lot of
this information is referenced from another guide from [Lawrence Systems](https://www.youtube.com/watch?v=VULKulpXBYU).

The first thing I have to do is delete the interface I've been using for LAN on the switch,
as I can't have any devices that are assigned to an interface as part of my link aggregation.
In pfsense I go to Interfaces and then assignments and delete my interface on `igb2`, noting
that I also have `igb3` available, with `igb0` being my WAN and `igb1` being my legacy
LAN, which I'm keeping around for the time being. Still on interfaces I switch over to
the `LAGG` tab and add an interface. I select `igb2` and `igb3` as parent interfaces,
set the LAGG protocol to LACP. I'll leave LACP Timeout mode on the default of `Slow`
and set the interface description to `igb2_3` because why not. After saving that I have
a new interface labelled `LAG0`. Back to the interface assignment tab I add an interface
on `LAGG0` and then click on its default name of `OPT1` to configure it. In the config
screen I check the box to enable it, give it a description of `LAN` (might change this
to Infra later since that's its intended purpose), set IPv4 Configuration type to static,
give it an IP address of `192.168.10.1/24` and hit save.

Next up I have to set some firewall rules so traffic can actually happen on this interface.
Head over to Firewall, Rules, and the LAN interface tab. I can't seem to set the auto
anti lockout rule for an interface other than the one I'm connected on, so I'll make a
poor man's version with a rule that allows traffic to `This firewall` on the https port
I set for management above. Then for now I'm just going to add an allow all style rule
because I want to deal with firewall rules separately later.

Last bit of config within pfsense I'll enable DHCP for this interface. This isn't
technically necessary, but it sure will make testing easier from my laptop. Under
Services, DHCP server, and then the tab for LAN I'll enable the DHCP server for this
interface and give it a range for dynamic assignments from `192.168.10.200` to
`192.168.10.250`. That should be more than enough since most of the devices on this
network should be infra and therefore have static IPs.

That should cover it for pfsense, so let's move over to the switch. I'm going to try
doing this from the menu so I head to `Switch Configuration` then `Port/Trunk` settings.
I set ports 1 and 2 to the group `Trk1` with type `LACP`, and hit save. At this point
I think I'm ok so let's plug in the cables and see what happens.

The first thing I check is if I can ping out from the switch. From the cli
`ping 192.168.10.1`  works, so that's a good start. I can also ping the switch IP from
my laptop which is still connected to `LegacyLAN`. This seems to be fine, but let's see
if I actually have redundancy. To do that I'll start pinging the switch from my laptop
(still on `LegacyLAN`) and then alternate unplugging cables from the switch. It works!
I miss a few sequences while it fails over, but still pretty good!

Last thing to check is that the other ports are now working regularly on the default
`LAN` network on the switch. Plugging into a random port I pull `192.168.10.200` and can
ping out to the internet and `LegacyLAN`. Looks like we're all good there, as would be
expected.

# Figure out actual address space for each network described

Before I go and create a ton of VLANs let's write out the planned networks I want and
their subnets.

* Infrastructure: This is called `LAN` right now and corresponds to the default VLAN on
  my switch. It's in the `192.168.10.0/24` range and unless I have to add my laptop into
  it because I can't get Wireguard to work the way I want then it doesn't need a VLAN tag
  because everything on it will be wired. Devices on this networks should be able to
  talk to devices on any other network as this is the main administrative network.
* Trust: For devices I know that I want to be able to access services. I'll open up
  access to servers within Infrastructure to this group, but not to the management interfaces
  for things like my firewall or switch. This will be on the `192.168.15.0/24` range, will
  use VLAN tag `15` I'm going to make them match to the third octet of the IP to make it
  easier to reason about. There will be wireless devices on this network so I'll have to
  create an additional `-trust` SSID beyond my regular one with the appropriate VLAN tag.
* Guest: For devices that just need internet access. My work machine, IoT devices, and
  whatever devices friends and family connect with will go on here by default. I'll keep
  this with the old SSID I was using to reduce the migration headache. This network will
  not be able to connect to anything but WAN, although I think I'll have to enable avahi
  for things like Chromecasts to work. This will be on the `192.168.30.0/24` range and
  VLAN tag `30`.
* Infrastructure Wireguard tunnel: For me to be able to administer the network from my
  laptop. Hopefully this will work both on site and remotely. That's the design plan for
  now at least. It will use the `192.168.20.0/24` range through a wireguard tunnel interface.
* Trust Wireguard tunnel: Similar to the trust internal network, but for remote access, either
  for myself or trusted friends and family. It will use the `192.168.25.0/24` range.
* OpenVPN tunnel: For connection to my offsite Synology. Synology only natively supports
  OpenVPN and I don't want to add complexity by either hacking in Wireguard or adding a
  device over there for routing. This will stay on the `192.168.90.0/24` range but I'll
  have to modify the firewall rules so it can talk to my NAS when I move it over to the
  Infrastructure network.
* LAB: This will be for VMs or other devices that I want to experiment with and don't
  want potentially impacting the rest of my network. I don't want to just put them on
  guest because I'm hoping to block traffic within that network as well, plus the IP
  address space will just be crowded. This will pretty much only be used by VMs in my
  proxmox cluster. It will be in the range `192.168.40.0/24` with the VLAN tag `40`. If
  for some weird reason I find the need to segment this further I'll use `41`, `42`, etc.

In addition to these intended networks I'll have a couple legacy networks around at least
for now. Legacy LAN is where everything will live until I migrate it over, and I'll probably
keep it around for quite a while (or maybe forever) just to be safe even after nothing is
connected to it. It's in the `192.168.85.0/24` range. I've also got my legacy wireguard
tunnel at `192.168.105.0/24`. I'll see if I can just turn that into the Trust Wireguard
tunnel since that's what everyone who's not me is using it for. I'll have to change
the address range and update the firewall rules but that should be ok.

# Test VLANs

Next up we have to see if I can get VLANs working. To start I'll just create one to make
sure it works before I go wild.

I'll start in pfsense under Interfaces, Assignments and then the VLAN tab. Let's do
the guest VLAN first since it has a simple firewall rule I can test easily. I set the
parent interface to `lagg0`, the VLAN tag to 30, leave the priority at 0, and set the
description to "Guest VLAN". Back on the Interface Assignments tab I select VLAN 30 from
the available network ports dropdown and click add. Then I click on the `Opt2` link to
configure the new network. I enable the interface, give it the description "Guest VLAN",
and set it to static IPv4 with an IP address of `192.168.30.1/24`. Save and apply and then
it's over to services to configure its DHCP server. On the GUESTVLAN tab I enable DHCP
and set the address pool to `192.168.30.100`-`192.168.30.250`. Even though most stuff on
here will just grab a random IP, I'll still use static maps for a lot of devices, so I
want to keep space free for that. Last up on the pfsense side I have to create some firewall
rules. First I add rules to block access to "this firewall" on the ssh and admin https ports.
For the next part there are going to be a bunch of networks that I want to block this
from access to, so I'll create an alias first. Under firewall, aliases, I add an alias
that includes the private networks I currently have configured, I'll extend it later.
I give it the name `private_networks` and then add entries for my Legacy LAN, LAN, and
OpenVPN network and hit save. Back in rules under GUESTVLAN I add a rule to block traffic
of any protocol to the alias `private_networks`, which should mean I can't connect to
anything outside my guest VLAN. At the bottom of the list I add an allow all rule so
that anything that isn't blocked by my rules above is allowed through.

Now over to the switch. I'm going to do this one through the menu at least, so I head
to Switch Configuration, VLAN Menu, VLAN Names. I create a new VLAN with ID 30 and name
Guest. Back one level to VLAN port assignments. First I set `Trk1`, my uplink aggregation
port to "Untagged" for the default VLAN and "Tagged" for the Guest VLAN. I mapped out
how I want to assign my ports and I know I'd like my work computer to go on port 14 so
I'll set it to "No" for the default VLAN and "tagged" for the guest. After saving it's
time to test.

# Create VLANs

# Create Wireguard Tunnels

# Create firewall rules

Don't forget about avahi for mdns and adding pfblocker to most everything.

# Set up SSIDs with VLAN tags

# Test with Laptop

# Move over services

See if you can move proxmox to DHCP and statically assign leases.