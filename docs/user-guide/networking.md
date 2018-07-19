# Networking
Every container can have one or more network interfaces. Currently, *osctl*
supports bridged and routed veth. [Routed veth] is an advanced method which is
useful for production deployments, so this page describes only bridged veth.

# Bridged veth
If you're running vpsAdminOS in a virtual machine using `make qemu`, you already
have bridge interface called `lxcbr0`. It has a preconfigured DHCP server
and NAT, which allows you to immediately use it in containers without any
further setup.

Network configuration is managed using the `osctl ct netif` family of commands,
see [man osctl] for a full description. Adding and removing a container's
network interfaces is only possible when the container is stopped. To add
a bridged veth interface to container `myct01`, use:

```bash
osctl ct netif new bridge --link lxcbr0 myct01 eth0
```

When the container starts, it will have interface `eth0` configured by DHCP.
It should be assigned an IP address and *just work* if you're using
a [supported distribution] within the container. Based on the container's
distribution, *osctld* is generating configuration files for the network
configuration, so that the container's init system will bring the interface up.

Bridged veth is fine for local and personal use, but we find that it's not
secure enough for production deployments, where each container can be controlled
by a different entity and cannot be trusted. Containers linked to the same bridge
can influence each other on the link layer. If that's a concern for your use-case,
see [routed veth].

[Routed veth]: ../networking/veth-routed.md
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
[supported distribution]: ../osctld/distributions.md
