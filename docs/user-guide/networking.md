# Networking
Every container can have one or more network interfaces. Currently, *osctl*
supports only bridged or routed veth. To add or remove an interface to/from
a container, the container has to be stopped.

## Bridge
vpsAdminOS has bridge `lxcbr0` by default, so unless you create your own bridge,
you can use this one. It comes with DHCP and NAT. To create a bridged interface,
use:

```bash
osctl ct netif new bridge --link lxcbr0 myct01 eth0
```

When the container starts, it will have interface `eth0` configured by DHCP.

## Routed veth
Routed veth is not linked with any bridge. Instead, the veth is routed on
a network layer using an interconnecting network, e.g. /30 IPv4 network
to connect the host and container veth pair. IP addresses belonging to the
container are then routed through the interconnecting network.
The advantage of routed veth over the bridged veth is that the interfaces are
isolated. The containers are not connected on the link layer.

For example, say we have an interconnecting network `10.100.10.100/30`. Host
veth will get IP `10.100.10.101` and container veth `10.100.10.102`.
Any IP address/network can then be routed to the container via the interconnecting
network. Let's route IP `1.2.3.4` to our container. On the host, we would add
the IP address from the interconnecting network and route `1.2.3.4` through
the veth to the container:

```bash
ip address add 10.100.10.101/30 dev $hostveth
ip route add 1.2.3.4/32 via 10.100.10.102 dev $hostveth
```

In the container, we'd first add the IP addresses from the interconnecting
network, then the routed IP address and finally set default route through
the host:

```bash
ip address add 10.100.10.102/30 dev eth1
ip address add 1.2.3.4/32 dev eth1
ip route add default via 10.100.10.101 src 1.2.3.4
```

You don't actually have to do that manually, because *osctld* manages all this
for you. What you need to do is to select the interconnecting network and then
assign IP addresses. *osctld* will manage the interfaces, addresses and routes.

```bash
osctl ct netif new routed --via 10.100.10.100/30 myct01 eth1
```

## IP addresses
Both bridged and routed veth support IP address management. IP addresses can
be added and removed even while the container is running.

```bash
osctl ct netif ip add myct01 eth0 1.2.3.4/32
osctl ct netif ip add myct01 eth0 5.6.7.8/32
osctl ct netif ip ls myct01 eth0
VERSION   ADDR       
4         1.2.3.4/32
4         5.6.7.8/32
```

IPv6 is supported as well.

## Container configuration
The commands above make the networking simply work, because *osctld* is also
managing network configuration inside the container. It generates configs
based on the container's distribution and uses the `ip` utility to configure
the network at runtime. Supported distributions include:

 - Debian
 - Ubuntu
 - Alpine Linux

Unless your distribution is supported by *osctld*, only the host will be
configured and you will have to configure the container networking on your own.
