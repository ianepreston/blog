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
connected to my WiFi shouldn't be able to connect to management interfaces
in my house for example.

A bonus goal is increased performance. My NAS has 4 rj45 ports that support
[link aggregation](https://en.wikipedia.org/wiki/Link_aggregation), and so does the
box that's running my pfsense router. While link aggregation can't boost the speed of
a single connection, and I don't do a ton of concurrent work on my network, having this
would still be nice. Credit to [this post](https://forum.netgate.com/topic/165219/same-vlan-on-multiple-interfaces/6)
for making me realize I should be using link aggregation with the router rather than
trying to split VLANs between multiple separately managed interfaces. *Addendum* I realize
later down in this that I want to use the multiple NAS ports to connect directly into
different networks, rather than do a big aggregation on one but still have everything
have to go through my router.

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
network communication (I think). *Addendum*: I ended up not going with this and just using
firewall rules.

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
a new interface labelled `LAGG0`. Back to the interface assignment tab I add an interface
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
  *Addendum*: Didn't end up using this.
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

# Setup VLANs

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

## Get sidetracked on issue with WSL

On my laptop plugged into a port other than 14 I pull a LAN IP address. I'm able to acces
the admin console of pfsense, and I can ssh in.

Unplugging from that port and moving over to 14 I initially seem to have my old IP. After
unplugging and plugging back in one more time now I'm pulling `169.254.49.68`, so something
appears to be broken. I bet I should have set port 14 to "Untagged" for Guest VLAN. My
laptop obviously isn't applying VLAN tags, that will make more sense for ports connected
to proxmox where I will be adding tags on VMs. Back to port 14. I pull `192.168.30.100`!
Great start. Ok but I can't connect to the internet or even ping my default gateway at
`192.168.30.1`. That's less good. Let's check my firewall rules. Back over to a regular
port so I can actually do that. Looking at the rules it looks like all the traffic is
blocked by my private networks rule. I don't see offhand why that would be the case,
but let's disable it and confirm that's the issue. Disabling it didn't fix things. Now
I'm noticing that my allow all rule was actually set to just allow TCP, so maybe that's
the problem? Ok, with that fixed I can access the internet. That's a good start. I can't
connect to the admin interface for pfsense, which is also intended behavior. I can't
seem to get online from within WSL though. I wonder if that's something about the connection
not being established with that VLAN tag originally? It shouldn't be a firewall rule right
now since I haven't turned the private networks rule back on. I do a reboot just to be safe.
Nope, that wasn't it. I can't even ping `192.168.30.1` from WSL. That's super strange.

This requires a better setup for testing. Something very weird is going on and I don't
want to try and solve it standing in my utility room. Fortunately I have a spare port in
my office upstairs, so I patch that one to the `.30` VLAN port and my workstation to a
port on the switch that doesn't have VLANs assigned. Back in the office I confirm that
I still have the same behaviour from my laptop on the `.30` and my workstation works
correctly on `.10`.

Back on the laptop, just for kicks mostly I try and connect to the network with
docker (which is running on top of WSL2) and it works?! Now my mind is really blown.

Let's try another experiment then. I'll swap my workstation over to the VLAN port and
see if its WSL can connect. Is it just something weird I didn't realize I did on my
laptop? Nope, exact same behaviour. Windows works fine, docker works fine, Ubuntu WSL
does not.

Time for some searching. There's [this GitHub issue](https://github.com/microsoft/WSL/issues/6001)
which describes similar behavior but it's a couple years old with no resolution. They
do have a request to collect and provide logs, depending on what I find I might come back
and contribute to this. There's [this GitHub issue](https://github.com/microsoft/WSL/issues/6410)
but in this case they're trying to add VLAN tags on the network adapter for the Windows
machine. The root cause might be similar, but the scenario isn't quite the same, and there's
no resolution listed anyway. There's [this GitHub issue](https://github.com/MicrosoftDocs/WSL/issues/507)
about applying a VLAN ID to the WSL network interface. That might work and might be worthwhile
for testing but I'd like to see if there's a cleaner fix. There's [this GitHub issue](https://github.com/microsoft/WSL/issues/6698)
that says the 8021q module isn't available in WSL. That appears to be true for me, but
shouldn't be relevant since I'm not trying to add my own VLAN tags, I'm just having
the switch assign them.

Well I'm running real low on ideas at this point so back at the first issue I run
their recommended log gathering script and put it up on the issue in a gist. I also add
the note about docker working ok in case that's a relevant clue to anyone who knows more
about WSL and networking than me. In the meantime let's take a look through the testing
output and see if anything jumps out.

I notice that I can't even ping the internal gateway of the WSL virtual network. I check
that on my workstation and I can't do it there either though, but it's able to get online
and talk to other devices in my network. I also can't ping the Windows host IP, but I can't
seem to do that from anywhere, including pfsense itself so I'm not sure what to make of that.

Running `traceroute` on WSL without the VLAN I can see it hit the internal WSL gateway,
then my `192.168.10.1` gateway, then the internet. Running it again on the WSL that's
on the VLAN it makes it to the WSL gateway (even though I can't ping it) and then times
out, it can't make it any further. Let's try that within docker on the machine with a
VLAN to see if that shows anything. After loading the container with
`docker pull ubuntu && docker run -it ubuntu /bin/bash` and installing the tools I need
with `apt update && apt upgrade && apt install inetutils-traceroute inetutils-ping`
I run traceroute on the machine behind a VLAN. It doesn't work? I reach the default
docker network gateway of `172.17.0.1` ok, head on to a gateway of `192.168.65.5` which
is super weird because I don't have that subnet configured anywhere and then time out.
But I can still ping out to the same internet site I was trying. Same thing for an internal
server. I can ping it and resolve the correct internal IP, but traceroute gets hung up
at `192.168.65.5`, which from some searching is the docker DNS server.
Let's try the same thing on the machine that's not behind a VLAN. Same behavior. What.
Let's try traceroute from the WSL of the machine that's not behind a VLAN. Works totally fine.
What is happening with these networks?

At this point I have to step back from this issue. There are no resolutions on GitHub,
and I've added my logs and comments to the issues in case anything comes up.
I've posted on Reddit and [serverfault](https://serverfault.com/) with no helpful response.

Fortunately, as long as docker works the impact of this on me is actually fairly minimal.
I'll keep my workstation in the Infra LAN without a tag so it will be fine. My laptop
won't be able to connect with WSL but I do almost everything Linux related on it from
devcontainers anyway. I might have to make an Infra SSID when I get to the wireless step,
just to have somewhere to connect from my laptop, but I don't expect to need it often.
As inconvenient as this is I don't think it's a showstopper so I'm going to move on. Maybe
I'll learn some more in the meantime that will be helpful.

*Note*: Below I find that this behaviour doesn't reproduce over WiFi. I'm so confused.

## Carry on with VLAN setup

At this point I think
it's worth setting up the basics of what I need in terms of VLANs. I'll save the firewall
rules for later, but I'll at least create the tags and interfaces. In the switch interface
I've already got my Infra VLAN (1, default) and Guest (30) VLAN names created so I just
have to add Trust (15) and Lab (40). Then it's down to VLAN port assignment. I've got
to update my trunk port to allow the new VLANs I've created, I'll do that first since
it's at the bottom of the list and otherwise I might forget it. The next two ports I'll
use for my wireless access points. I want the APs themselves to be on my infra network
so I'll set the default VLAN to untagged. They're also going to be creating guest and
trust networks when I get to that point so I turn tags 15 and 30 on. I don't see anything
in my lab/dev environment being wireless so I'll leave that off for now. The next four
ports I'll eventually use for my NAS. It's got four connections on it so I can have one
for each network. I originally thought about just putting them all into infra with link
aggregation, but after watching some more Lawrence Systems videos I realized that it
makes more sense to have them on each network directly so I'm not putting load on my router
whenever I'm using the NAS, as I would be if the NAS was on Infra and most of the devices
accessing it were on trust or guest. With that in mind for the next four ports I'll set
each one to untagged for a single VLAN (default/infra, trust, guest, lab in order) and
`No` for the other VLANs. Next up we've got my three proxmox nodes. Those should be
on infra by default, but I want to be able to add lab VMs, so I'll turn VLAN 40 on. I
don't think anything in there makes sense for trust or guest, so I'll leave that off.
Just a handy reminder for myself here, the options `auto` and `forbid` are for if
GVRP is enabled on my switch, which as discussed above, it is not. The next two ports
are for my current standalone server and my workstation, both of which I'm putting on
infra, so the default VLAN gets left as `untagged` and the other VLANs are set to `No`.
The last two devices are my work computer and a Hue bridge for my lights, both of which
belong on guest, so I set that VLAN to `untagged` and `No` for the other VLANs.

Now over on pfsense I have to create the VLANs, add DHCP for them, and (for now) give
them a nice open "allow all" type firewall rule. The process is the same as what I described
in the guest VLAN above so I won't write it out again.

# Migrate Services

## Proxmox

Changing proxmox might be tricky since it uses static IPs. Presumably if I go in and
change my network config I will lose connectivity until I move the host over to the
new network. This will probably also do fun things to my cluster and ceph setup. That's
ok though, I'm not running anything production on there yet, that's part of why I wanted
to do this network rework now.

The first thing I do is remove the static leases I was using in pfsense to ensure name
resolution of the proxmox hosts. This means I have to connect in from their IPs, but
that's ok. I'll add in name resolution again later. Now on the proxmox hosts, I'll do
this one at a time. On the first one under system I go to DNS and update the DNS server
to the new gateway. I add the old one in as a secondary one for now. Next I modify the
hosts section to identify the new IP I'm going to give this host (192.168.10.11, I'll
leave 2-10 for more foundational infrastructure and start in the tens to match the
PVE node number). Finally, and here's where things will break until I switch ports,
I go to the network section and update the `vmbr0` interface to the new address range.
I get prompted to either apply changes or reboot. A reboot seems safer so I go for that
and while that's happening I head downstairs and move it over to the correct port on the
switch. Backupstairs I can access it again from the new IP! It can no longer see the
other two nodes, so maybe there's something about not clustering across broadcast ranges.
That's fine, I'll update the other two and then work on getting ceph set back up. After
connecting the second node back it gets the correct IP and can join, but it can't see
the first node. Going up to the datacenter page in proxmox it looks like all the nodenames
are still pointing to the old IP addresses, maybe name resolution isn't working in pfsense?

I know I could do host overrides in the DNS server settings in pfsense, but I like assigning
static leases to devices so I can see all the IP addresses I'm using from the DHCP page.
There might be other things I can do with DNS to auto identify hostnames but I'm going to
save that for later (either later in this post or another post). In pfsense I apply static
leases for the two nodes I've moved over (glad I copied that when I deleted their leases
on the old network). Doing this allows me to ping and correctly resolve the name for the
other node but I still don't see them in the cluster. In the
[proxmox docs](https://pve.proxmox.com/wiki/Cluster_Manager#_cluster_network) it looks like
I have to edit `/etc/pve/corosync.conf`. There are also some handy docs on
[editing corosync](https://pve.proxmox.com/wiki/Cluster_Manager#pvecm_edit_corosync_conf),
which include incrementing the version. I can't follow them though because even as root
the file is read only. [This post](https://forum.proxmox.com/threads/cmd-access-is-good-gui-access-is-bad.106482/)
is from someone having the exact same issue as me, it's because my nodes don't have quorum
because I took them down so cluster settings get locked. That's totally sensible, probably
should have thought of that before I tried migrating. Reading [these docs](https://pve.proxmox.com/pve-docs/chapter-pvecm.html#_remove_a_cluster_node) it looks like I can remove nodes from the cluster, but then
I'm going to have a bad time and have to reinstall them to get them back in. Let's back
up and try doing this a bit more gracefully. I'll reset the first two nodes to their old
address and put them back on the old switch just to make sure I can get back to a known
good state and then more slowly move them over. Back in pfsense I remove the static
mappings for the two nodes on the infra network and add then back in the legacy network.
I change the host config and IP settings on the nodes and reboot them. Down to the utility
room to plug them back into the old switch. Ok, we're back up with quorum. Now to figure
out the smart way to do this migration.
[Adding redundant links](https://pve.proxmox.com/pve-docs/chapter-pvecm.html#_adding_redundant_links_to_an_existing_cluster)
feels like it should work, but the different links can't talk to each other, so I'm not
sure if I'll get in a weird in between state partway through. I guess it should recover
once all three nodes are on the new network. Let's give it a shot. Given that this is
already risky let's follow the recommendations in the docs for editing corosync.
On my first proxmox node I copy the current corosync config into a `.new` and `.bak`
copy:

```bash
cp /etc/pve/corosync.conf /etc/pve/corosync.conf.new
cp /etc/pve/corosync.conf /etc/pve/corosync.conf.bak
```

Then I edit the new file. For each node I add an entry for `ring1_addr:` with the IP
I'm migrating to. In the totem I increment the `config_version:` field. Finally I duplicate
the interface section with link number 1. Let's just check it on another node to make
sure things are syncing properly. Yup, it's over on my other node. Move the `.new` file
to overwrite the original config and I should be good to go. Let's try migrating again.

I move the static leases over from legacy LAN to Infra. This time I'm going to change
all three nodes over at once and power them off, move the network cables over, and then
bring them all back up. Let's see if it works.

They came back up, and I can ping all of them at their new address. I can even ssh into
them, but the web interface isn't loading. So that's fun. Ok, even weirder. I actually
just can't access the web interface for the first node. All three show as joined to my
datacenter though and I can access the first node from the web interfaces of the other
two. That's pretty close to functional, just have to figure out this first web interface.
Maybe it just needs a reboot? Worth a shot at least. Ok, that did it. Not really sure
why that did it, but who ever knows why rebooting fixes things?

Last up, let's get rid of the old addresses from the corosync config. I make another
`.new` copy, edit it to remove the old `ring0` address and change the updated `ring1`
address to be `ring0`, increment the `config_version` and get rid of the second interface.
Checking the cluster info from the datacenter page I see all three nodes using the correct
IP on the first interface. Success!

### CEPH

I'm sure all these address changes have done interesting things to my CEPH cluster. Let's
try and get that back on track now. On one of my nodes I head over to the CEPH tab and
check the configuration page. I can't seem to update anything from the web portal
so let's try making changes in the terminal to `/etc/pve/ceph.conf`.
I update `cluster_network`, `mon_host`, `public_network` and the `mon` settings for each node.

Still getting timeouts from CEPH, probably because it has to reload something? Let's just
reboot all the nodes again to be safe and see what happens. Still nothing. The config seems
to have been applied but I don't see anything. Running `pveceph status` or `ceph -s` just
times out. Looking back on my [previous effort](2023-02-05-proxmox-ceph.md) let's see if
I can find some good troubleshooting steps. The first thing I did was initialize ceph
if `pveceph status` showed "not initialized" so I'm going to skip that.
`pgrep ceph-mon` shows no monitors running but `pgrep ceph-mgr` and `pgrep ceph-osd`
both show processes. Interestingly in the web interface I can see all three monitors,
just with status "unknown", but I can't see any managers or OSDs.

Just as an aside here. I recognize I'm almost certainly going to spend more time
troubleshooting this than I would just rebuilding the cluster. Especially since I went
to all that effor to configure things with ansible. I'm treating this as a learning
opportunity, not a productivity hack.

Reviewing the docs I find [this handy warning](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/#changing-a-monitor-s-ip-address)
that existing monitors are not supposed to change their IP address. From reading
[this](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/#changing-a-monitor-s-ip-address-the-right-way)
I'm basically hooped unless I move all three nodes back to the old IP address range and
even then I'm not sure I could painstakingly migrate one node at a time without losing
quorum on either my ceph cluster or my proxmox cluster. In summary, don't expect to
be able to migrate a proxmox cluster over to a new address range, it's going to be a
rebuild.

I still want to try a bit more here before I give up on rebuilding ceph. Mostly because
I'm stubborn, partially because it will help me understand how ceph works.

Checking what I still have running for ceph related processes I find the following:

```bash
root@pve3:~# ps ax | grep ceph
   1621 ?        Ss     0:00 /usr/bin/python3.9 /usr/bin/ceph-crash
   2478 ?        Ssl    0:01 /usr/bin/ceph-osd -f --cluster ceph --id 0 --setuser ceph --setgroup ceph
   6658 pts/0    S+     0:00 grep ceph
```

The result is the same on all three of my nodes. Taking a look at
[this forum](https://forum.proxmox.com/threads/unexpected-ceph-behaviour-from-unused-ceph-installation.95229/)
gives me a tip to check the status of `ceph-crash` which in turn gives me this error:

```Apr 15 13:17:33 pve1 ceph-crash[1421]: ERROR:ceph-crash:directory /var/lib/ceph/crash/posted does not exist; please create```

After creating that directory I don't see any records getting created.

Looks like I can stop the running `ceph-osd` with `systemctl stop ceph-osd.target` I still
have the `ceph-crash` service running and even if I kill it the process comes back,
so it's being triggered by some service. Running `systemctl --type=service --state=running`
I can see there's the `ceph-crash` service so I stop that on each node. After running that
it doesn't seem like I have any more CEPH services running. Let's try a purge again.

```bash
root@pve3:~# pveceph purge --crash --logs
Error gathering ceph info, already purged? Message: got timeout
Foreign MON address in ceph.conf. Keeping config & keyrings
```

So no luck there. Let's try [this post](https://forum.proxmox.com/threads/not-able-to-use-pveceph-purge-to-completely-remove-ceph.59606/)
and run the following on each node:

```bash
rm -rf /etc/systemd/system/ceph*
killall -9 ceph-mon ceph-mgr ceph-mds
rm -rf /var/lib/ceph/mon/  /var/lib/ceph/mgr/  /var/lib/ceph/mds/
rm /etc/pve/ceph.conf
```

Now I need to wipe my disks to get ready to start again. Initially when I try and
wipe it from the menu I get a warning about the device having a holder. From
[this forum](https://forum.proxmox.com/threads/sda-has-a-holder.97771/) post I learn to
run `lsblk | grep ceph` to find the id and then `dmsetup remove <the id I found>`.
After this I can wipe the disks.

Let's see if I can rebuild the cluster using my ansible playbook from last time. After
modifying it with the new network addresses of course. I can initialize the ceph cluster
but creating monitors fails because I don't have `/var/lib/ceph/mon` to create monitors
in. Fine, I create that folder on each node and then try adding monitors. Same thing
fore creating managers, have to create `/var/lib/ceph/mgr`, might as well recreate
`/var/lib/ceph/mds` while I'm at it. This whole experience is really making me rethink
integrating distributed storage with my hypervisor. Let's try creating an OSD.
Here's where things fall apart again: `auth: unable to find a keyring on /etc/pve/priv/ceph.client.bootstrap-osd.keyring: (2) No such file or directory`

Ok. That's enough of this. This is way off topic for figuring out my network and it's pretty
clear that I'm going to have to come back and figure out my distributed storage solution
again.

## NFS

After all that I realized my NFS share wasn't loading anymore. After thinking for a second
I realized that made sense since my NFS rules only allowed connections from the `192.168.85.0/24`
range. Adding a new rule for the infra range fixed that up. *Addendum*: I did this for my
proxmox shared folder but not for the rest of them here, this bites me later in the NAS
migration section.

## VMs with VLAN Tags

For now let's make sure creating VMs with VLAN tags works the way I think it should
and move on. I'll have to come back to refiguring my storage in a future post. First
I create a VM with no VLAN tag assigned to the network interface and DHCP settings.
It comes up and gives me an IP in the correct range. I could just create a new one, but
let's see what happens if I just shut this down and change the VLAN tag on the interface?
On the hardware tab I go to the network interface and give it a VLAN tag of 40. It pulls
the new IP when it comes back up and works perfectly. Finally something goes well!

## Migrate Synology and prod server

Now that I have my VLANs setup, it's time to migrate my NAS over. To start I'm going to
shutdown my production server so it doesn't get any weird behavior while things are
shifting over. Once I've got the Synology back up I'll migrate it to the new Infra LAN
as well. I can head into the "Info Center" and then Network section of the Synology
control panel to get MAC addresses for each interface. This will allow me to create
static routes in pfsense to give correct IP addresses. On the infra LAN the next free
IP address after the gateway and switch is `192.168.10.3` so I'll assign that to the NAS.
I'll keep the same pattern of making it `192.168.x.3` on each network for consistency.
For hostnames I'll just use the name I've assigned the nas on infra, and all other networks
I'll prepend the network name to distinguish. After adding in all the static mappings and
confirming the order I set the ports on the VLAN it's time to head down to the utility
room and move some cables around. When I come back upstairs I'm delighted to see that
I can ping all the interfaces at the IP I expected. I have to flush my DNS cache before
I can ping the original hostname on the infra IP, but otherwise this part is smooth
sailing. Let's bring up my prod server and see if all my services still work. It came
back up ok and it picked up the new IP, but only some of my docker containers are coming
back. Again, that's out of scope for this so I'll just re-run my ansible playbook for
setting up this machine and see if that resolves it. Ok, the problem was that I had volumes
specified with reference to the old IP address. Even though the associated containers weren't
running, they still had a claim on those volumes and so ansible couldn't remove and re-add
them. After stopping all containers and removing them I re-ran the playbook and realized
I had to update the NFS share permissions on my other shares to allow access from the
Infra network. This was actually one of the reasons I wanted to migrate over. NFS is not
secure (at least without some fancy user auth tied in that I've never bothered to setup)
so having it only available on my infra network and using SMB everywhere else will enhance
my security. While I was at this I moved my media box over to my guest network and after
a bit of fiddling with kodi settings to point to the new share that's on the guest network
things all came back up.

## Migrate the last couple wired devices

Beyond what I've moved over so far the only wired devices I have left are my work computer,
a Hue bridge for lights, and my access points. I'll deal with the access points when
it's time to migrate the SSIDs in the coming section. The last two devices went smoothly
and joined the guest network as I'd expect them to. I still haven't set any firewall
rules so the guest network isn't actually any more/less secure right now, but at least
they're joining the correct network and nothing is immediately breaking.

# Set up SSIDs with VLAN tags

This part is a little scary because almost all of my devices in this house are on WiFi
so if I break this I'm going to have a bad time. I think I'm just going to prove out the
actual VLAN activity working and that nothing breaks just by being on a different network
before I set up firewall rules. Right now my APs are still on my unmanaged switch. I think
I first want to create new SSIDs with VLAN tags, confirm that doesn't break anything on
the unmanaged side, and then move them over to the managed switch and see what happens.

Over in my unifi controller portal the first thing I have to do is create networks for
each of the VLANs I'm using. On the networks panel I add two networks named \[Trust/Guest\]VLAN
and give them the appropriate VLAN tags. Over on WiFi I'm going to keep my existing SSID
and just make it the guest network. This seems like the easiest way to handle migration
and it will reduce confusion for guests. I'll change the network for that one from `default`
to `GuestVLAN`. I'm not going to make it a guest network at this point, I'm not even sure
what that will do if my router isn't Unifi. I'll handle firewall rules in pfsense later.
I make a second network for the trust VLAN and I should be basically good to go. At this
point my controller can't actually see my APs. I can ping them from the server that's running
it, but I think since they're on different networks some broadcast that they're using for
discovery isn't working. I'm guessing/hoping that all I'll have to do to address this is
move them over to the other network. Down in the utility room again I change over the APs
to their designated ports on the switch. They both come back up and pick up the static
leases I assigned for them. Checking the Unifi console both of them show up with the
status "Adopting", which is better than not visible at all. While the adoption is happening
I take a look at my phone. I am online, but I've pulled an IP in the `Infra` range, so
the VLAN tags aren't being applied yet. That makes sense given the APs are still adopting
so they wouldn't have been able to incorporate any configs. The Unifi web interface now
has them cycling between "Adopting" and "Offline" although I can still consistently ping
them. I think something about moving my controller has broken the APs connections. I perform
a factory reset on the APs and try again. Something about the credentials don't seem to
be working. Let's try forgetting the AP and re-adopting it. It feels like it should
work, I even get a notification that the AP has been adopted, but it still hangs on
adotping. Still not working. Let's try a firmware update on the AP through ssh.

Ok, firmware is updated, devices have been rebooted. I've also set the existing entries
for both devices to "Forget" in the web UI. Both of them show back up as adoptable. I click
adopt on one of them and eventually it just shows up as offline in the web portal even
though I can still ssh into it. Let's try another factory reset now that I've done
the firmware update. After running that command I can't ssh back into it. Power cycle the
AP to see if that comes back up. Hmm, it comes back up but the firmware version is back.
Looking at the AP it seems to start off with the default inform address, but when I set
it to the correct one it goes back to the old IP of my controller server. After a bit
of searching I realize that this is because I had to hard code the inform IP setting in
the controller so it didn't use the docker IP of the container it was in, and that was
set to my old IP. Let's try adopting again. Ok! One of them at least has switched over
to "Getting Ready". That's farther than I've made it before. After a bit more waiting
they both come back online. What a relief. Checking my phone I am now pulling an IP in
the `192.168.30.0/24` range so it looks like VLAN tags worked too!

I'm super curious at this point to see how my laptop will respond to getting VLAN tags
from the WiFi. Will I still not be able to connect with WSL? I can?!? I'm so extra strength
confused right now. Connecting to either SSID pulls the correct IP and WSL works just fine.
Running traceroute confirms that it is routing traffic through the correct gateway address
for whichever VLAN I'm on. Just to make sure I'm not totally losing it I plug back into
the cable for my work machine that's on the guest VLAN and confirm I can reproduce the
failure on WSL. I can. I have absolutely no idea what to make of this.

# Create Wireguard Tunnels

Now I need to deal with wireguard. Right now my tunnel allows communication
to my legacy LAN. It also uses `.105` for the third octet which was closer to my old IP
addressing scheme. To match my IP scheme a bit closer I'm going to move my
Wireguard tunnel over to `192.168.25.0/24` to it's close to the trust network range of
`192.168.15.0/24`, that doesn't actually do anything inherently, it just makes it easier
for me to keep straight in my head. On the wireguard peers I have to adjust their allowed
IP ranges to cover that new range as well. Further, on the client for the peers I have
to adjust the allowed IPs to cover the Infra LAN (I'll handle specific access
to infra with firewall rules, but some services on that network have to be routable).

I was originally going to make two wireguard tunnels and handle firewall rules at that
level, but upon further consideration I think it will be easier to just set rules for
specific devices than bother with all that.

At this point I think Wireguard itself is basically correctly configured.

# Set up static leases

This part isn't strictly necessary, but I like using static leases for all devices on my
network so it's easy to spot new additions and also to allow for hostname resolution. In
pfsense I'll keep one window on the leases under my legacy LAN since that will help me
figure out the identity of devices I've previously given static leases, and also allow
me to clear off their old leases. In the other Window I'll check each of my newly created
networks and ensure that they have the devices I'd expect. Checking my existing leases
everything that doesn't currently have a static lease is on my guest network, which is
perfect since everything I added on other networks I gave a static lease so I shouldn't
be seeing anything there. After spending a little while confused about why I couldn't see
my iPhone to give it a static lease I noticed it had a setting turned on for "Pivate WiFi
access". Somehow this not only hides my MAC address but the IP it gets doesn't even show
up in my list of DHCP leases. That's pretty neat, but also sneaky. For my home network
I'm turning that setting off on the phone so I can give it a private address. Doing this
is also a good opportunity to make sure I actually can identify all the devices on my
network. For instance I got real confused by something labelled android but eventually
realized it was the tablet panel for my security system.

# Make sure everything works before adding firewall rules

At this point I've got a bunch of stuff on different networks, but no actual security
since everything is still allowed to route to everything. In theory this should mean that
I won't have any issues at this stage but as I've seen at several other points in this
adventure that's not always actually true. Before I add more complexity with firewall
rules I'm going to step through all my devices and make sure they still work as I'd expect.

It does! What a nice surprise after all the weird twists I've encountered going through
this.

# Create firewall rules

Now we're at the part where I actually add some security to all this network segmentation
I've been doing.

First I'm going to create some aliases to make things a bit easier on myself. The first
one I'll make I'll label `pfsense_admin` and include the ports for https and ssh access
to the router, since I don't want anything touching that. I can also use it to create
my own anti-lockout rules for my infra LAN, since the default one from pfsense is tied
to my legacy LAN. I'll also create an alias for my devices on wireguard, as I'll want
them to have elevated access relative others I grant VPN access to. Next I'll create a
"web" port alias for 80 and 443. Right now my services are on http but I'd like to move
them to https in the future.

## Wireguard rules

I'm not going through these in any particular order beyond the order they happen to
be in for my firewall rules tabs. I currently just have an allow all type rule on this
interface so I need to restrict things a bit. The first rule I'll add is to allow my
laptops to access anything. I'll make that the top rule and then I can add other rules
below. Anyone else using this service is accessing either my file share over samba or
one of the production services I'm running on my standalone machine. I add allow rules
for samba by opening port 445 to my NAS IP, and the "web" alias port to my server. I
also better allow access to this firewall since it's providing DNS if nothing else, but
I'll block the admin ports first and then create an allow rule for the firewall generally.
Rules are evaluated top to bottom so the block on admin ports will apply and then the allow
on all other ports will follow. There might be a way to combine those rules but I'm going
to try this for now. I don't want anything else to happen through VPN so I can finally
disable the allow all rule I had to start (I could just delete it but whatever).

Testing the rules from my phone on LTE work the way I'd expect. I can access my web
portals but I can't get into the firewall web interface. I tried testing my laptop tethered
to my phone in hotspot mode but couldn't get it working. I couldn't even get regular web
traffic happening while the VPN was on. Wireguard is set for split tunneling so I wonder
if that's something about the hotspot having protections in place rather than an actual
restriction. I'm going to leave testing the rest of this for now. Next time I'm out with
my laptop I'll try some other tests. Coming back to this after some reboots this is
working as expected so I'm going to leave it alone.

## Guest LAN rules

First rule I need is blocking admin access to the firewall, using the alias I already
created. Next I'll create an alias for all my private networks, which is everything
except this one and the WAN and block access to that. After that I just need an allow
all rule. This one's actually pretty straightforward rules wise. One more thing I have
to open is access from my Kodi box to the port on my prod server where I'm hosting its
mariadb database. I also have to add a rule so my kobo can talk to my calibre server.

Testing these rules I'm delighted to find that everything still works. My robot vacuum
needed a reboot when I loaded it on the app, but maybe that was a coincidence?

## Trust LAN rules

This one should be easy as well. I block access to the admin portal on the router,
create an alias for my switch and access points and block that as well.

This works as expected. As a bonus, on my laptop if I connect through my wireguard tunnel
I can access the router admin page, but I can't without the tunnel, so the extra permissions
on Wireguard seem to work even if I'm still on my local network as well.

# Scream test

I'm not really calling this done at this point. I've done all the testing I can think
of and things appear to be performing the way I'd expect them to. But as I've seen
above, networking impacts basically everything so I'm going to leave this for at least
a week before I fully relax. I'm not going to wait to publish this that long though,
if anything comes up I'll come back here and edit this.

# Conclusion

Networking is hard. Not so much because of VLANs or Firewall rules themselves. Those
are actually fairly straightforward (except with WSL for whatever reason). The challenge
is in thinking about all the services you have and how they all talk to each other. So
many little hard coded configs that I didn't think about, or access rules that I hadn't
considered. I'm still glad I did this because I learned a lot and my network will be
in better shape for the future, but man, what an effort.
