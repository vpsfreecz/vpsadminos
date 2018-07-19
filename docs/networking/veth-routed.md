# Routed veth
Unlike [bridged veth], the created veth is not linked with any bridge interface.
Instead, the veth is routed on a network layer using an interconnecting network,
e.g. /30 IPv4 network to connect the host and container veth pair. IP addresses
belonging to the container are then routed through the interconnecting network.
The advantage of routed veth over the bridged veth is that the interfaces are
isolated. The containers are not connected on the link layer.

Routed veth requires manual setup of the network environment. You either need
software for dynamic routing, such as OSPF or BGP, or configure static routes
for the IP addresses routed to containers. Without any setup, the routed
addresses will be reachable only locally between the host and containers.

## Example configuration
For example, say we have an interconnecting network `10.100.10.100/30`. Host
veth will get IP `10.100.10.101` and container veth `10.100.10.102`.
Any IP address/network can then be routed to the container via the interconnecting
network.

IP `1.2.3.4/32` would be routed to the container from the host like this:

```bash
ip address add 10.100.10.101/30 dev $hostveth
ip route add 1.2.3.4/32 via 10.100.10.102 dev $hostveth
```

The first command adds address from the interconnecting network to the
host's veth interface. This needs to be done only once. The second command
adds route for `1.2.3.4/32` to the container via `10.100.10.102`, which is
the container's address from the interconnecting network.

In the container, we'd first add the IP addresses from the interconnecting
network, then the routed IP address and finally set the default route via
the host:

```bash
ip address add 10.100.10.102/30 dev eth0
ip address add 1.2.3.4/32 dev eth0
ip route add default via 10.100.10.101 src 1.2.3.4
```

You don't actually have to do any of that manually, because *osctld* manages all
this in the background. What you need to do is to select the interconnecting
network and then assign IP addresses. *osctld* will manage the interfaces,
addresses and routes. The example configuration would be created as:

```bash
osctl ct netif new routed --via 10.100.10.100/30 myct01 eth0
osctl ct netif ip add myct01 eth0 1.2.3.4/32
```

## Interconnecting networks
The interconnecting network has to have at least two addresses: one for the host
and one for the container. For IPv4, minimal prefix is `/30`, for IPv6 it's
`/126`. By default, the host gets the first address from the network and the
container gets the second address. The assigned interconnecting addresses
can be changed if needed:

```bash
# Create routed veth with custom addresses
osctl ct netif new routed --via 10.0.0.0/24 \
                          --host-addr 10.0.0.254 \
                          --ct-addr 10.0.0.1 \
                          myct01 eth0

# Change existing interface
osctl ct netif set --via 10.0.0.0/24 \
                   --host-addr 10.0.0.254 \
                   --ct-addr 10.0.0.1 \
                   myct01 eth0
```

With this configuration, the container gets the first address while the host
gets the last address. It's possible to reuse public addresses as interconnecting
addresses like this. The same can be done for IPv6, where if you assign e.g. `/64`
prefixes, it can be used both as public and interconnecting network.

## IP addresses
It's important to distinguish addresses that are routed to the container and
addresses that are assigned to the container's interfaces. The assigned addresses
are a subset of the routed addresses. It is possible to route larger networks
and assign selected addresses to the container's interface.

Routes are managed using `osctl ct netif route` commands:

```bash
osctl ct netif route add myct01 eth0 10.5.5.0/24
```

The command above will route network `10.5.5.0/24` to the container, but no
address will be assigned to its interface yet. Addresses are managed using
`osctl ct netif ip` commands:

```bash
osctl ct netif ip add myct01 eth0 10.5.5.1/24
```

To make the usage more straightforward, `osctl ct netif ip add` will
automatically add route for the added address, unless there is one already
present. This behaviour can be controlled by CLI options, see [man osctl] for
more information.

[bridged veth]: veth-bridge.md
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
