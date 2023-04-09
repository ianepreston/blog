---
title: "Setting up my first managed switch"
date: '2023-04-08'
description: "I picked up a cheap HP procurve 2810, let's get it working"
layout: post
toc: true
categories: [networking, Linux]
---

# Introduction

After some [recent challenges](2023-02-24-k8s-the-hard-way.md) where experiments in my
lab took down DNS for my entire network, I decided it was time to stop putting off
cleaning up my network from the giant flat architecture it's currently using.

To accomplish this goal I first needed to acquire a managed switch. Following a great deal
of searching and talking myself into and out of getting some super fancy 10gb switch with
PoE I found [an hp 2810-48g](https://www.hpe.com/psnow/doc/c04140686?jumpid=in_lit-psnow-red)
for $15 from a local reseller and decided it made more sense to pick that up and learn
before committing to anything super fancy and expensive. As with most of my recent posts,
this is going to be a log of the things I tried and issues I encountered, as opposed to
a polished how-to guide for others to follow. Although, if you're in a similar position
to me at the start of this post, then maybe reading through will save you some pain
on your own journey.

# Connecting to the switch

If I'm going to manage this switch, I need some way to connect with it. Right now it's
not even assigned an IP, and from my reading these types of switches don't just pick one
up by default. Instead I have to connect in over the management interface, which is a
port that looks like ethernet on the switch, but is actually a serial console. I ordered
in a RJ-45 to USB cable to handle this connection and hooked it up to one of the boxes
I had down by the switch. I also ran a regular ethernet cable from the first port on the
switch to one of the unused interface ports on my pfsense router. I'll set up a separate
network on that and slowly migrate devices onto this switch as I get it working.

Anyway, with the connection established physically, I have to figure out how to connect
in from the machine. I ssh into the box the switch is connected to and run `lsusb`.
`Bus 003 Device 002: ID 0403:6001 Future Technology Devices International, Ltd FT232 Serial (UART) I`
looks like the right device. How do I connect to it? Well first I reboot because I realize
I haven't rebooted since I upgraded the kernel on this machine and I think that's giving
me problems accessing kernel modules [as seen here](https://bbs.archlinux.org/viewtopic.php?id=211536).
The reboot also leads to `/dev/ttyUSB0` showing up, which was what I was looking for when
I started poking around with `lsusb` and `dmesg`. Following the console connection
[docs from pfsense](https://docs.netgate.com/pfsense/en/latest/hardware/connect-to-console.html)
I run `sudo screen /dev/ttyUSB0 115200` and
just get a blank screen. After waiting a fair while and almost giving up I'm greeted with
the procurve screen!

```
ProCurve J9022A Switch 2810-48G
Software revision N.10.02

Copyright (C) 1991-2006 Hewlett-Packard Co.  All Rights Reserved.

                           RESTRICTED RIGHTS LEGEND

 Use, duplication, or disclosure by the Government is subject to restrictions
 as set forth in subdivision (b) (3) (ii) of the Rights in Technical Data and
 Computer Software clause at 52.227-7013.

         HEWLETT-PACKARD COMPANY, 3000 Hanover St., Palo Alto, CA 94303

We'd like to keep you up to date about:
  * Software feature updates
  * New product announcements
  * Special events

Please register your products now at:  www.ProCurve.com




Press any key to continue
```

# Connect in and bring up setup

Now I've got a nice prompt saying `ProCurve Switch 2810-48G#`. So now what?
According to the manual I can just type `setup`, that's handy, let's give that a shot.

```
ProCurve Switch 2810-48G                                    7-Jan-1990  18:21:16
==========================- CONSOLE - MANAGER MODE -============================
                                  Switch Setup

  System Name : ProCurve Switch 2810-48G
  System Contact :
  Manager Password :                    Confirm Password :
  Logon Default : CLI                   Time Zone [0] : 0
  Community Name : public               Spanning Tree Enabled [No] : No

  Default Gateway :
  Time Sync Method [None] : TIMEP
  TimeP Mode [Disabled] : Disabled

  IP Config [DHCP/Bootp] : DHCP/Bootp
  IP Address  :
  Subnet Mask :


 Actions->   Cancel     Edit     Save     Help
```

That's pretty neat. At this point I guess I better set up the router to actually
operate on that port. Over in pfsense I go to `Interfaces -> Interface Assignments`.
I've got `igb0` set as my WAN, `igb1` as my (currently only) LAN, and nothing on `igb2`,
which I assume is the port my switch is plugged into since I plugged it in beside the
other two. Let's create an interface there and call it `LABLan` for now. After adding
the interface I head into the options, mark it enabled, rename it from the default `Opt1`
and give it an IP address of `192.168.10.1/24`. Eventually I'm going to have to refigure
my addressing scheme, but for now that space isn't in use so let's go with it.

# Test basic connectivity

I think at this point I can give my switch an IP address and connect into it that way.
Let's try. I change the IP Config to manual and then enter an IP address of `192.168.85.2`
and a subnet mask of `255.255.255.0`. Let's test this. To avoid potential routing or
firewall problems as an issue I'll first start by just trying to ping it from a shell
on pfsense. I get a response! Good start. Let's see if I can ping it from my LAN on
another machine, probably not. Yeah, I can't. Eventually I'm going to lock these different
networks down, but for now while I'm testing let's see if I can open things up. Again,
I'll clean this up later, but for now I'm just adding a rule that passes any traffic
from `LAN` net to `LABLan` net. But ping still doesn't work. Why would that be? Probably
because I didn't add a rule that allowed outbound traffic from `LABLan`. Getting closer,
at least now my switch can ping the default gateway where it couldn't before. But I still
can't seem to ping it from my other network. Let's take a step back and see if I can ping
that gateway from my network. I can, so that suggests the network rules are working.
But then why can't I ping the switch? Running `traceroute` from another machine shows
it reaching the gateway at `192.168.10.1` but not making it through to the switch.

I've simplified my firewall rule for that interface even further with just allowing
pass everywhere, but it's still not working.

I want to try pinging out from the switch, but for whatever reason connecting in
again using the same `sudo screen /dev/ttyUSB0 115200` that was working before is not
rendering well anymore. Guess I'll get sidetracked and work on that.

# Get sidetracked on the serial interface

## Try some other consoles and commands

For whatever reason upon trying to reconnect I'm getting either nothing from the terminal
or some random gibberish characters, or parts of what seem to be the prompt or menu
screen, but not rendered correctly to actually read. I assume there's something wrong
with how my serial connection is configured. I tried connecting with `minicom` instead,
and got similar results. I tried connecting at different baud rates, but that also didn't
imporve things. I read that the switch would auto-negotiate based on whatever rate I first
connected to it with, so I reset the switch and tried connecting at `38400` since I'd
seen that in some guides, but it was still basically the same. At least I learned the
proper way to end a `screen` session with `ctrl+a` and then `k`.

## Realize I can telnet in

Now that I have an IP address assigned, it looks like I can `telnet` in from pfsense
with `telnet 192.168.10.2`. I'd still like to get the serial interface figured out as
a fallback, but at least this lets me work through the menus while I'm figuring that out.

Just as a quick first test I see if I can ping out from the switch, and I cannot. I can
ping my default gateway, but I can't ping anything on the LAN or internet. That's weird,
but I'm coming back to that later, right now we're getting the serial console working
properly.

From the telnet session I run `show console` to get my serial config:

```
 Console/Serial Link

  Inbound Telnet Enabled [Yes] : Yes
  Web Agent Enabled [Yes] : Yes
  Terminal Type [VT100] : VT100
  Screen Refresh Interval (sec) [3] : 3
  Displayed Events [All] : All

  Baud Rate [Speed Sense] : speed-sense
  Flow Control [XON/XOFF] : XON/XOFF
  Session Inactivity Time (min) [0] : 0
```

## Try with hard coded baud rates and putty, finally figure it out (sort of)

Let's try hard coding the baud rate to what I'm using. First I run `config` to get into
config mode, then `console baud-rate 115200` to set the rate, then `write memory` to
save the setting, and `reload` to reboot the switch. After giving it a minute to come
back up I re-run my screen command. Still doesn't work. I wonder if this is some weird
quirk of trying to do things over ssh. Let's connect my laptop directly and try it out.
That will introduce the added factor of using putty into the mix, but oh well.

Working with putty seemed to work a bit better. I still ended up with blank screens
but with a bit of fussing around I was able to get it started up again. I wonder if
I just left it in a weird state before and if I can get back in cleanly remotely now.

Ok yeah, that seems to be it. I guess I'll have to remember to leave the session in a
clean state. Let's see if I can quit out and come back in. I can, ok, must have just
been something about the state I left it in. Back to actually setting up this switch.

Actually, one more thing. Let's set the baud-rate back to auto. Again from the switch
I run `config` to get into config mode, then `console baud-rate speed-sense` then
`write memory` then `reload`. After rebooting the switch I reconnect with
`sudo screen /dev/ttyUSB0` without specifying a speed. It auto connects at 9600 baud,
which seems to work fine.

# Set up routing

Back to actually making this thing work for networking. I have an IP address for the
switch, and I can reach that from my router, and I can reach the router from my switch,
but I can't get out to the internet or my other networks from the switch, or into the
switch from my other networks. What gives?

As part of the test I decide to see if I can connect my NAS into this network on one
of its other ports. I go in, give it a static IP on that port (since I haven't enabled
DHCP on this interface yet) and... get locked out of my NAS on the LAN interface. I'm able
to confirm that I can ping the NAS from my switch now, but I've taken down my NAS from
my main network, which is definitely not good. I'll go unplug that cable and hope my NAS
comes back. Oh good, it did. Still have to figure out what's up with my routing though.

I guess this is a good point to do a manual backup of my pfsense setup. I should have
backups going automatically, but this seems like a time to have a little extra insurance.

Oh wait, I think my LAN firewall rules only allow outgoing traffic from other networks.
I probably have to add an allow rule to receive traffic from LabLAN. Nope, still can't
ping.

Just to restate where I'm at, from my LAN connected computer at `192.168.85.2` I can
ping the `LabLAN` gateway at `192.168.10.1`, but not the switch at `192.168.10.2`.
From the pfsense router I can ping the switch at `192.168.10.2` and from the switch I can
ping the `LabLAN` gateway at `192.168.10.1` but not the `LAN` gateway at `192.168.85.1`.
For the brief period when I had my NAS connected on that interface I could ping it from
the switch, although that also messed up my connectivity on `LAN` for the NAS, so I turned
that off while I'm testing.

After some poking around I decide to check the output of the `show ip` command on 
the switch:

```
ProCurve Switch 2810-48G# show ip

 Internet (IP) Service


  Default Gateway :
  Default TTL     : 64
  Arp Age         : 20

  VLAN         | IP Config  IP Address      Subnet Mask     Proxy ARP
  ------------ + ---------- --------------- --------------- ---------
  DEFAULT_VLAN | Manual     192.168.10.2    255.255.255.0   No
```

So I don't have a default gateway set. That would do it. Looking back I didn't write
down anything about setting that. Oops.

I run setup again, I set the default gateway to `192.168.10.1` and everything works.
I can see how I missed that now, the default gateway setting is well above where you set
the IP of the switch. Well that was a waste of a fair bit of time.

# Try the web interface

I know all the hardcore network people use the shell, and maybe at some point I'll do
that too, but I'd at least like the option of a network interface. Let's see if I can
get my hands on that.

Opening up a browser and loading the IP of the switch I get:

`This product requires the Java language, which is either disabled or not available on this browser.`

`To use this product you must either upgrade your browser to one that is Java compliant, or enable the Java language on your current browser.`

From checking out [this post](https://community.spiceworks.com/topic/1146093-hp-procurve-java-application-blocked)
it seems like I'd have to have a very old browser to use this web interface. Fine,
guess it's menus and CLIs for me.

# Conclusion

In this post I demonstrated that I don't really know a lot about networking and that
this is going to be quite the learning experience. I also got the basic connectivity
working on my managed switch. In the next post I'll do some actual planning for my
network and start configuring things and moving services over.
