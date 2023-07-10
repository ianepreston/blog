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

# See if I can do some parsing on those before I do actual change based operations

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

So one last thing in terms of info gathering. I'd like to know the state in terms of
VLAN settings for all of my ports, plus the device associated with them if I have that:

```python
def vlan_status(conn):
    """Get the VLAN assignment of each port, along with a name if you can."""
    vlans = get_vlans(conn)
    vlan_nums = [x["vlan_num"] for x in vlans]
    # vlan_desc = {x["vlan_num"]: f'{x["vlan_num"]}_{x["vlan_name"]}' for x in vlans}
    all_ports = {
        str(port): {k: "" for k in ["name"] + vlan_nums} for port in range(3, 49)
    }
    # Assign names to ports I know
    for k, v in map_devices_to_ports(conn).items():
        all_ports[v]["name"] = k
    # Associate VLAN tags
    for vlan in vlan_nums:
        port_dicts = get_vlan_ports(conn, int(vlan))
        for port_dict in port_dicts:
            port = port_dict["port"]
            state = port_dict["state"]
            all_ports[port][vlan] = state

    return all_ports
```

I had to do a few hacky things because I haven't thought through my data structures very
well, but I'm ok with this, it does the trick. Now for every port I get a name if I know
the device as well as the status of ever VLAN in terms of "tagged", "untagged" or an
empty string for not applied. I start at port 3 because I have the first two trunked to
my router and I don't expect to have to change them and because they're trunk ports I
can't just show ports 1 and 2.

# Do actual modifications to the switch config

Let's experiment with configuring an actual port the way I want it. The way the commands
work in the HP console is operations are performed on VLANs based on ports, so something
like `vlan 30 tagged 1-5` would allow traffic tagged with VLAN 30 on ports 1-5. I think
of things more in terms of how I want ports to behave, so my preferred syntax would be
something like `port 5 v30 tagged v15 untagged` to set port 5 to accept tagged traffic
on VLAN 30 and mark untagged traffic as being on VLAN 15. There's probably clever ways
to bundle together my current state and desired state and only execute the commands necessary
to reconcile them, but let's do some building block stuff and figure out how to just change
a particular VLAN assignment on a particular port to start.

```python
def set_port_vlan_state(conn, port: int, vlan: int, state: str):
    """Set VLAN state on a port."""
    command = f"vlan {vlan} {state} {port}"
    x = conn.send_config_set(command)
    return True
```

This "works" but doesn't account for a lot of edge cases. For one thing, I can only
enable VLANs as either tagged or untagged with this. If I want to disable them I need
to add a flag that will add a "no" to the command. However, if I do that, I also need
to ensure I'm not ending up in an invalid state, as I have to have at least one VLAN
enabled either tagged or untagged on any given port. I think based on this it might
make more sense to try and do a comprehensive remapping rather than individual steps.

To start I'll make a constant at the top of the script called `DESIRED_STATE` in the
same format as the output of `vlan_status`. This should make it easier to reconcile and
also lets me copy paste the output of `vlan_status` to do the initial population.

Let's write a little helper function to do basic validation on this `DESIRED_STATE`. I won't
be able to catch everything that could be wrong here, especially not just misconfiguration,
but I can get the basics:

```python
def validate_desired_state():
    """Make sure my desired state will actually work."""
    # We'll catch VLANs actually existing later, just make sure we're consistent
    reference_keys = set(DESIRED_LAYOUT["3"].keys())
    correct_states = {"", "Untagged", "Tagged"}
    for k, v in DESIRED_LAYOUT.items():
        states = set(pv for pk, pv in v.items() if pk != "name")
        if states - correct_states:
            raise RuntimeError(
                f"Unknown VLAN status on port {k}: {states - correct_states}"
            )
        if set(v.keys()) != reference_keys:
            raise RuntimeError(f"Keys for port {k} don't match port 3")
        untagged_count = len([x for x in v.values() if x == "Untagged"])
        if untagged_count > 1:
            raise RuntimeError(f"Port {k} has more than one VLAN set to untagged")
        if untagged_count == 0:
            raise RuntimeError(f"Port {k} has no VLAN specified for untagged")
```

Now we can do something to compare the current state and the desired state, and return
any ports that don't reconcile:

```python
def check_vlan_status(current_state: dict):
    """Is the current state the same as the desired state?"""
    # Check names first
    mismatch_names = dict()
    for k in current_state.keys():
        if (
            current_state[k]["name"] != DESIRED_LAYOUT[k]["name"]
            # Allow for devices to just be turned off
            and current_state[k]["name"] != ""
        ):
            mismatch_names[
                k
            ] = f"Current Name: {current_state[k]['name']}, Desired Name: {DESIRED_LAYOUT[k]['name']}"
    if mismatch_names:
        print("Names don't match on some ports")
        for k, v in mismatch_names.items():
            print(f"Port: {k} {v}")
        raise RuntimeError("Port name mismatch")
    # Make sure we're working with the same VLANs
    desired_vlans = {
        key
        for vlans in DESIRED_LAYOUT.values()
        for key in vlans.keys()
        if key != "name"
    }
    current_vlans = {
        key for vlans in current_state.values() for key in vlans.keys() if key != "name"
    }
    if desired_vlans != current_vlans:
        print(
            f"VLANs don't match. Current state: {current_vlans} Desired: {desired_vlans}"
        )
        raise RuntimeError("VLAN selection mismatch")
    # If names are all good check ports
    mismatched_ports = dict()
    for k, v in DESIRED_LAYOUT.items():
        for vlan in current_vlans:
            if DESIRED_LAYOUT[k][vlan] != current_state[k][vlan]:
                mismatched_ports[k] = DESIRED_LAYOUT[k]
                break
    return mismatched_ports
```

We do a little more runtime checking to make sure that devices I think are in a particular
port aren't showing up elsewhere. Note that I want to be able to run this with some devices
powered down, as I may want to only bring them up after reconfiguring their ports, so I
allow for the name identified in the current state to be an empty string. Then we make
sure I have the right VLANs in my desired state, so I haven't created or deleted any
from my current state that I think I should have. If all that goes well I go through
each port and if I find a mismatch in VLAN config I add the desired state to a `mismatched_ports`
dictionary that I can pass into some reconcilliation function later.

While doing some testing for this I got my switch into a weird state where I got
intermitent errors running the script, even on functions that had worked fine before.
I gave the switch a reboot to see if I could clear things up and that seemed to work, but
it does add to how sketchy this whole setup feels. This is probably going to get filed under
"learning activity" rather than "thing I use to manage my environment". We'll see though.

I did get a function that would update the configuration of a port to match what I want
from a desired state dictionary:

```python
def set_port_vlan_state(conn, port: str, state: dict):
    """Set VLAN state on a port."""
    # Get rid of the name key
    state.pop("name", None)
    vlans = set(state.keys())
    # Should only be one untagged VLAN and we validate that elsewhere.
    untagged_vlan = [k for k, v in state.items() if v == "Untagged"][0]
    tagged_vlan = [k for k, v in state.items() if v == "Tagged"]
    # Set the untagged VLAN first so we definitely don't end up orphaned.
    commands = [
        f"vlan {untagged_vlan} untagged {port}",
    ]
    # Turn off untagged explicitly for all other VLANs
    for vlan in vlans - {untagged_vlan}:
        commands.append(f"no vlan {vlan} untagged {port}")
    # set tagged vlans
    for vlan in tagged_vlan:
        commands.append(f"vlan {vlan} tagged {port}")
    # Turn off tags on other VLANs
    for vlan in vlans - set(t for t in tagged_vlan):
        commands.append(f"no vlan {vlan} tagged {port}")
    # Now save the desired config
    commands.append("write memory")
    conn.send_config_set(commands)
```

I still run into hanging the connection to the switch from time to time with it, but
maybe that's not as big a deal given how infrequently I'll actually be doing this outside
of developing the script. The last thing I have to do is put that together with the list
of unreconciled ports that I created into one big function:

```python
def reconcile(conn):
    """Bring the current state of the switch in line with the desired state."""
    validate_desired_state()
    current_state = vlan_status(conn)
    mismatches = check_vlan_status(current_state)
    if mismatches:
        for port, state in mismatches.items():
            set_port_vlan_state(conn, port, state)
```

And that appears to work!

# Conclusion

I'm pretty sure this is not what most people are talking about when they say "software
defined networking", and there were many hacky parts to the setup. On the other hand,
it's slightly easier for me to modify my switch setup in the future, I learned a bit
more about managing my switch, and I got to practice my python. Overall I'd call
that a win.
