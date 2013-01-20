Description
===========

This plugin to Chef's Knife command line tool, is intended to be used to
automate the provisioning, bootstrapping and verification of VM instances in a
Chef managed environment.

It is designed to support any virtualization infrastructure or cloud provider
that has an API we can use to automate the process. However, VMware vSphere® API
is the only supported infrastructure at the moment. 

Usage
=====

The caterer subcommand expects two main arguments: an environment, and a data
bag item describing the environment's composition. The composition data bag item
is expected to be found in an data bag named after the environment, e.g., based
on 'data_bags/staging/composition.json'. It is read from the Chef server, not
local disk, so any changes need to be updated at the Chef server before they
will be applied.

### Composition

The composition data bag item contains several sections:

+ `vc` - information about the provisioning datacenter (currently only a VMware
   vSphere® endpoint).
+ `templates` - VM templates to be used when provisioning VM
  instances.
+ `networks` - networks provisioned VMs may be connected to. Needed
  networking configuration information will be pulled from these when the VMs
  are provisioned/customized.
+ `actors` - VM classes to be provisioned. Each actor has its own run
  list, resources (CPUs, RAM), number of instances to provision, and acceptance
  tests that verify the provisioning and bootstrapping were successful.

### Execution

The caterer subcommand supports assigning actors to different phases of the
provisioning process. This can be used to make sure some actors are provisioned
and verified before others.

In each phase, the subcommand will verify against existing resources the state
of each VM instance, provisioning missing instances as needed. Existing VMs that
fail verification will cause the subcommand to error out, expecting an operator
to fix the issue (which might be by deleting the failing VM instance) before
running the command again.

#### Example

This sample composition will provision a name server, two DHCP servers (one for
each network used), and two redis servers (one on each network).

The provisioning is devided into several phases:

1. The name server.
2. DHCP servers.
3. Redis servers.

The name and DHCP servers are provisioned using static IP addresses, while the
redis servers will be expected to use DHCP (the provisioning will configure the
customization process to do so). The name and redis servers have acceptance
tests defined.

    {
        "id" : "composition",
        "vc" : {
            "itvc" : { 
                "type" : "vsphere",
                "vsphere_host" : "vc.example.com",
                "template-folder" : "/",
                "datastore" : "NFS_Datastore01",
                "vm_folder" : "Chef-provisioned",
                "resource_pool" : "Chef_managed_cluster/staging",
                "vsphere_dc" : "IT",
                "vsphere_user" : "chef",
                "vsphere_pass" : "password",
                "insecure" : "true"
            }
        },
        "networks" : {
            "dmz" : {
                "vlan" : "Vlan1",
                "vc" : "itvc",
                "dns" : "8.8.8.8",
                "subnet" : "10.116.0.0/16",
                "gateway" : "10.116.0.1",
                "domain" : "staging.loc"
            },
            "secure" : {
                "vlan" : "Vlan2",
                "vc" : "itvc",
                "dns" : "8.8.8.8",
                "subnet" : "10.216.0.0/16",
                "gateway" : "10.216.0.1",
                "domain" : "staging.loc"
            }
        },
        "templates" : {
            "ubuntu-base" : {
                "name" : "ubuntu-base-10.04",
                "vc" : "itvc",
                "user" : "sysadmin",
                "key" : "id_ubuntu_base",
                "os" : "ubuntu",
                "folder" : "/"
            }
        },
        "actors" : {
            "ns" : {
                "instances" : 1,
                "addresses" : [ "10.116.255.254" ],
                "vcs" : [ "itvc" ],
                "run-list" : [ "role[nameserver]" ],
                "networks" : [ "dmz" ],
                "template" : "ubuntu-base",
                "cpus" : 1,
                "memoryGB" : 1,
                "phase": 0,
                "acceptance-test" : {
                    "tester" : "nameserver",
                    "args" : [
                        "<%= node['ipaddress'] %>",
                        "<%= node['domain'] %>",
                        "<%= node['hostname'] %>"
                    ]
                }
            },
            "dhcp-secure" : {
                "instances" : 1,
                "addresses" : [ "10.216.255.253" ],
                "vcs" : [ "itvc" ],
                "run-list" : [ "role[dhcp-secure]" ],
                "networks" : [ "secure" ],
                "template" : "ubuntu-base",
                "cpus" : 1,
                "memoryGB" : 1,
                "phase": 1
            },
            "dhcp-dmz" : {
                "instances" : 1,
                "addresses" : [ "10.116.255.253" ],
                "vcs" : [ "itvc" ],
                "run-list" : [ "role[dhcp-dmz]" ],
                "networks" : [ "dmz" ],
                "template" : "ubuntu-base",
                "cpus" : 1,
                "memoryGB" : 1,
                "phase": 1
            },
            "redis-secure" : {
                "instances" : 1,
                "addresses" : [],
                "vcs" : [ "itvc" ],
                "run-list" : [ "role[redis]" ],
                "networks" : [ "secure" ],
                "template" : "ubuntu-base",
                "cpus" : 1,
                "memoryGB" : 2,
                "phase": 2,
                "acceptance-test" : {
                    "tester" : "redis",
                    "args" : [ "<%= node['ipaddress'] %>", "<%= node['redis']['port'] %>" ]
                }
            },
            "redis-dmz" : {
                "instances" : 1,
                "addresses" : [],
                "vcs" : [ "itvc" ],
                "run-list" : [ "role[redis]" ],
                "networks" : [ "dmz" ],
                "template" : "ubuntu-base",
                "cpus" : 1,
                "memoryGB" : 2,
                "phase": 2,
                "acceptance-test" : {
                    "tester" : "redis",
                    "args" : [ "<%= node['ipaddress'] %>", "<%= node['redis']['port'] %>" ]
                }
            }
        }
    }

License and Author
==================

Author:: Leeor Aharon (<leeor@cloudshare.com>)

Copyright 2013 CloudShare, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
