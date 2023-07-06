---
title: "Automating my network"
date: '2023-07-06'
description: "Overengineering at its finest"
layout: post
toc: true
categories: [networking]
---

# Introduction

In a [previous post](2023-04-08-managed-switch.md) I set up a managed switch in my network,
but I did it all manually through the menus. Realistically that's fine, I don't have a super
big or complicated network and I don't move things around enough to justify the investment
in learning how to automate it in terms of time savings. But I like automating things,
so let's see what I can figure out.

# What I'd have liked to do

Ideally I would handle this through Ansible, since that's what I use to do most of the
rest of my home automation. Unfortunately, my switch is not one of the supported devices
in Ansible's networking stack as near as I can tell. The next best thing would have been
to use [NAPALM](https://napalm.readthedocs.io/en/latest/) for python based automation,
but that's also not supported. So I have to go one level down the stack and use
[netmiko](https://pypi.org/project/netmiko/). Let's see how that goes.

# Connecting to the switch

In the previous post I connected using the serial console and then telnet. For netmiko
to work I will need SSH. This does not appear to be enabled by default. After checking
the manual it looks like enabling this is a command line only operation. From the initial
login I'm in the manager level interface and my prompt looks like this: `ProCurve Switch 2810-48G#`
I need to get from there to the Global configuration level by running `config` so it
looks like this `ProCurve Switch 2810-48G(config)#` and then run `crypto key generate ssh`
to create a host key on the switch, `ip ssh` to enable ssh, and then `show ip ssh` to
confirm that it worked.

After this I'll try and connect to the switch and find that it's got too old a key
exchange method to work by default:

```bash
Unable to negotiate with 192.168.10.2 port 22: no matching key exchange method found. Their offer: diffie-hellman-group1
```

After finding a bunch of other out of date security protocols that my ssh client didn't
support by default (probably a good reason to not have this switch in the enterprise anymore)
I was able to get it working with the following ssh config:

```bash
Host switch
    User admin
    HostName 192.168.10.2
    KexAlgorithms +diffie-hellman-group1-sha1
    PubkeyAcceptedAlgorithms +ssh-rsa
    HostkeyAlgorithms +ssh-rsa
    Ciphers +3des-cbc
```

With that set I can now ssh into my switch. Let's try and actually do something with
netmiko.

The baby connection test script that I used looks like this:

```python
import netmiko
from getpass import getpass

device = {
    "ip": "192.168.10.2",
    "device_type": "hp_procurve",
    "username": "admin",
    "password": getpass("Enter password for the switch:\n"),
}

with netmiko.ConnectHandler(**device) as connection:
    print(connection)
```

which does print out a signature for a connection object. I don't have any actual info
on the switch itself, but it appears to be working as I was getting a connection error
before I configured ssh properly.

We can do something a little more interesting that also validates the connection by
modifying the last two lines to:

```python
with netmiko.ConnectHandler(**device) as conn:
    sys_info = conn.send_command("show system-information")

print(sys_info)
```

This indeed prints out the system info, so the connection is working.

# Figuring out the commands I need

Last time I worked on this I just did everything with the menu because I was lazy. If I'm
going to automate things I will need to use the CLI, so let's identify the commands I need
and what their outputs look like.

- `show vlan` will list all my VLANs
- `show vlan <vlan#>` will list a specific VLAN as well as any ports that do tagged
  or untagged traffic for that VLAN
- `show mac-address [<port>]` show mac addresses seen by the switch, optionally specify
  for a particular port. Returns them in format `######-######`

## See if I can do some parsing on those before I do actual change based operations

So far I haven't identified the commands necessary to actually modify my setup, but let's
see if I can do some easy parsing on these to begin with.

I'll try `show vlan` to start. With a little bit of string parsing I can get a nice looking
output:

```python
def get_vlans(conn) -> list[dict[str, str]]:
    """Get VLAN info.

    Returns a list of dictionaries with keys for
    vlan_num, vlan_name and vlan_status, all as strings.
    """
    base_output = conn.send_command("show vlan")
    output_list = [line.strip() for line in base_output.split("\n") if line.strip()]
    vlan_list = [line.split() for line in output_list if re.match(r"\d+\ ", line)]
    vlan_dict = [
        {"vlan_num": line[0], "vlan_name": line[1], "vlan_status": line[2]}
        for line in vlan_list
    ]
    return vlan_dict
```

Which returns something like:

```python
[
  {'vlan_num': '1', 'vlan_name': 'DEFAULT_VLAN', 'vlan_status': 'Port-based'},
  {'vlan_num': '15', 'vlan_name': 'TRUST', 'vlan_status': 'Port-based'},
  {'vlan_num': '30', 'vlan_name': 'Guest', 'vlan_status': 'Port-based'},
  {'vlan_num': '40', 'vlan_name': 'LAB', 'vlan_status': 'Port-based'}
]
```

I can probably do something for showing a particular VLAN:

```python
def get_vlan_ports(conn, vlan_num):
    """Get the ports associated with a vlan and their tagged or default status."""
    base_output = conn.send_command(f"show vlan {vlan_num}")
    output_list = [line.strip() for line in base_output.split("\n") if line.strip()]
    vlan_list = [line.split() for line in output_list if re.match(r"\d+\ ", line)]
    vlan_dict = [{"port": line[0], "state": line[1]} for line in vlan_list]
    return vlan_dict
```

Which gets me something like:

```python
[{'port': '3', 'state': 'Tagged'}, {'port': '7', 'state': 'Tagged'}, {'port': '15', 'state': 'Untagged'}]
```

For the MAC address I'm going to make a little helper function to do some string formatting
first, as the formatting for MAC addresses from the switch is different than what I see
in most other places. I want to be able to just copy paste from anywhere and have them
comparable. This is a one liner: `re.sub("[^0-9]", "", mac)` in a function that takes `mac`
as an argument. After that we have a similar pattern except in this case I'm going to return
a dictionary where each key is a MAC address and each value is its associated port:

```python
def get_mac_ports(conn):
    """Get MAC addresses seen by the switch and their ports."""
    base_output = conn.send_command("show mac-address")
    output_list = [line.strip() for line in base_output.split("\n") if line.strip()]
    mac_list = [
        line.split() for line in output_list if re.match(r"[\da-fA-F]{6}", line)
    ]
    mac_dict = {mac_parser(line[0]): line[1] for line in mac_list}
    return mac_dict
```

With this if I have a dictionary with keys being the MAC addresses of my devices and
values being the names of those devices, I can find what devices are on what ports
in an automated way (if they're on, the switch only shows current connections).

```python
def map_devices_to_ports(conn):
    mac_dict = get_mac_ports(conn)
    home_ports = {v: mac_dict.get(k) for k, v in home_macs.items()}
    return home_ports
```
