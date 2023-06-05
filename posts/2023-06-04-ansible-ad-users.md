---
title: "Finding all AD group users with ansible"
date: '2023-06-04'
description: "LDAP search is your friend, but you'll have to do some string parsing"
layout: post
toc: true
categories: [ansible, Linux]
---

# Introduction

This is a write up summarizing the process I went through to retrieve information about
members of Active Directory groups from a Linux VM using ansible. My specific intent was
to use it as part of a playbook to configure [rootless docker](https://docs.docker.com/engine/security/rootless/),
but it would be applicable in any other situation where you need to get the members of
a number of AD groups. The hardest part of it by far is getting the output of earlier
tasks into a format that's suitable for later steps. I've got a reasonable clean approach
documented below, after trying some extremely ugly alternate approaches earlier. I'm sure
there's some even fancier way to do this that will make my approach look silly, and if you
know it I'd love for you to fill me in.

# Pre-requisites

In order to do this I need the user ansible is running as to be authenticated against
Active Directory. I don't have elevated privileges on the AD I tested this on, so I think
any normal user account should be sufficient. For this example I have my username and
password stored as variables `ad_user` and `ad_password`.

I've also got a host variable configured for each host I'm doing this on that maps to a
list of AD groups I want members of for that host, called `domain_groups` in this playbook.

Having set this up I need to make sure the host machine has a pre-requisite module available,
and that the user I'm running as has a kerberos ticket issued for my user:

```yml
- name: Install ldap pre-requisites
  become: true
  ansible.builtin.apt:
    pkg:
      - python3-ldap

- name: Issue a kerberos ticket to authenticate to AD
  ansible.builtin.shell: |
    echo "{{ ad_password }}" | kinit -l 1h {{ ad_user }}@example.com
  changed_when: false
```

I've changed the actual domain to `example.com` and you'll need to modify that to your
domain of course.

# Get the users

```yml
- name: Return all users in the groups associated with the machine using LDAP search
  community.general.ldap_search:
    dn: "cn={{ item }},cn=Users,dc=EXAMPLE,dc=COM"
    sasl_class: "gssapi"
    server_uri: "ldap://example.com"
    attrs:
      - member
  register: intermediate_calc_group_members
  with_items: "{{ domain_groups }}"
```

This first part does the actual data retrieval, everything that follows is just cleanup.
For reference, the JSON I get out of this looks something like:

```json
{
            "ansible_loop_var": "item",
            "changed": false,
            "failed": false,
            "invocation": {
                "module_args": {
                    "attrs": [
                        "member"
                    ],
                    "bind_dn": null,
                    "bind_pw": "",
                    "dn": "cn=group1,cn=Users,dc=EXAMPLE,dc=COM",
                    "filter": "(objectClass=*)",
                    "referrals_chasing": "anonymous",
                    "sasl_class": "gssapi",
                    "schema": false,
                    "scope": "base",
                    "server_uri": "ldap://example.com",
                    "start_tls": false,
                    "validate_certs": true
                }
            },
            "item": "group1",
            "results": [
                {
                    "dn": "cn=group1,cn=Users,dc=EXAMPLE,dc=COM",
                    "member": [
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Synced to Azure,OU=Example Client,OU=Example Corporate,dc=EXAMPLE,dc=COM"
                    ]
                }
            ]
        },
        {
            "ansible_loop_var": "item",
            "changed": false,
            "failed": false,
            "invocation": {
                "module_args": {
                    "attrs": [
                        "member"
                    ],
                    "bind_dn": null,
                    "bind_pw": "",
                    "dn": "cn=group2,cn=Users,dc=EXAMPLE,dc=COM",
                    "filter": "(objectClass=*)",
                    "referrals_chasing": "anonymous",
                    "sasl_class": "gssapi",
                    "schema": false,
                    "scope": "base",
                    "server_uri": "ldap://example.com",
                    "start_tls": false,
                    "validate_certs": true
                }
            },
            "item": "group2",
            "results": [
                {
                    "dn": "cn=group2,cn=Users,dc=EXAMPLE,dc=COM",
                    "member": [
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,CN=Users,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM",
                        "CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM"
                    ]
                }
            ]
        }
```

In the example above I've replaced all the actual user names with `example_user` but you can
see that the information I want to assemble (the usernames and which group each of them is in)
is surrounded by a lot of extraneous data and text.

```yml
- name: Get group and member list
  set_fact:
    intermediate_calc_users: >-
      {%- set result = [] -%}
      {%- for play_dict in intermediate_calc_group_members.results -%}
        {%- for user in play_dict['results'][0]['member'] -%}
          {%- set clean_user = user | regex_search('^CN=(\\w\\d+),.+', '\\1') | first | lower -%}
          {{
            result.append({'group': play_dict['item'], 'id': clean_user, 'user': clean_user + "@EXAMPLE.COM"})
          }}
        {%- endfor -%}
      {%- endfor -%}
      {{ result | to_json | from_json }}
```

Some parts of this are witchcraft to me. I don't really know why I have to pipe my
result to json and then back from json. It's doing something to clean up my variables
in such a way that subsequent steps can understand it, but as for why I'm not really sure.
I got a lot of the structure of this variable construction from
[this post](https://stackoverflow.com/questions/58727924/convert-nested-list-of-dicts-to-dict-in-ansible).

The regex I'm using in this particular case is based on the fact that all the user IDs I'm
working with are in the format of one letter followed by several numbers. If your user IDs
are more heterogeneous you'll have to mess with the regext to get just the username out
of that part of the output that looks something like:

```json
"CN=example_user,OU=Example Clients,OU=Example Corporate,dc=EXAMPLE,dc=COM"
```

At the end of this step I have a list of dictionaries with one entry per user with keys
for their AD group, just their username, and their username with the domain appended.

Note that this step will fail if you pull an AD group that only has one member, because
the `member` item in the dictionary will go from being a list to a string. I didn't specifically
have to deal with that in my use case, but it would be more robust to do something like
putting `play_dict['results'][0]['member']` in a list and then flattening that list so
you always got a list back.

```yml
- name: Register getent results so I can retrieve UIDs
  ansible.builtin.getent:
    database: passwd
    key: "{{ item.user }}"
  with_items: "{{ intermediate_calc_users }}"
  register: intermediate_calc_getent
```

For my particular use case in addition to the usernames I also needed the UIDs of each
user, so in this step I use ansible's built in `getent` module and the dictionary I created
above in the last step to return the entry in `/etc/passwd` for each user, which will include
their UID.

```yml
- name: Cleanup getent results
  set_fact:
    intermediate_calc_getent_clean: >-
      {%- set result = [] -%}
      {%- for play_dict in intermediate_calc_getent.results -%}
        {%- set getent_passwd = play_dict['ansible_facts']['getent_passwd'] -%}
        {%- set key = getent_passwd.keys() | first -%}
        {{ result.append({'key': key,'value': getent_passwd[key][1]}) }}
      {%- endfor -%}
      {{ result | items2dict | to_json | from_json }}
```

Again, this step is a bit of black magic, just messing around with the output of the
last step (ansible's debug is your friend for this) and fiddling with it until I have a
list of dictionaries with one item where the key is the username and the value is their
UID.

```yml
- name: Create final list of dicts for all users
  set_fact:
    users_dict: >-
      {%- set result = [] -%}
      {%- for user in intermediate_calc_users -%}
        {{ result.append({'group': user['group'], 'user': user['user'], 'user': user['user'], 'uid': intermediate_calc_getent_clean[user['user']]})}}
      {%- endfor -%}
      {{ result | to_json | from_json }}
```

Now all I have to do is combine those two dictionaries together into one. This part
is pretty self explanatory except for that `to_json | from_json` bit at the bottom.

# Conclusion

If you work with Linux systems where users are managed by AD (or probably other LDAP providers,
but I'm using AD in this example) then this is a handy trick to get a fact in your playbook
with basic information about those users.