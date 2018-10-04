# Routed veth
Unlike [bridged veth], the created veth is not linked with any bridge interface.
Instead, the veth is routed on a network layer using configured routes.
The advantage of routed veth over the bridged veth is that the interfaces are
isolated. The containers are not connected on the link layer.

Routed veth requires manual setup of the network environment. You either need
software for dynamic routing, such as OSPF or BGP, or to configure static routes
for the IP addresses routed to containers. Without any setup, the routed
addresses will be reachable only locally between the host and containers.

## Usage
Let's see how can the routed veth be used:

Create new routed interface in container `myct01` as `eth0`:
```
osctl ct netif new routed myct01 eth0
```

Add a single IP address:
```
osctl ct netif ip add myct01 eth0 1.2.3.4/32
```

Route a larger network and assign one IP address from the network:
```
osctl ct netif ip add --route-as 10.0.0.0/24 myct01 eth0 10.0.0.1/24
```

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

## Routing
Before you start using it, it's important to understand how the routed veth
works. Routing addresses from the host to the container is straightforward,
routes are added to the host's veth interface, e.g.:

```
ip route add <routed address> dev $hostveth
```

However, routing *from* the container is more complicated. The container's
default route has to be routed via the host's IP address. For this purpose,
*osctld* creates a dummy interface on the host and adds one IPv4 address through
which all IPv4 traffic is routed. IPv6 traffic is routed through link-local
addresses assigned to veth interfaces on the host.

```
# Host
ip link add osrtr0 type dummy
ip address add 255.255.255.254/32 dev osrtr0

# Containers
ip route add 255.255.255.254/32 dev $ctveth
ip route add default via 255.255.255.254 dev $ctveth
```

## Example configuration
IP address `1.2.3.4/32` would be routed to container from the host like this:

```bash
ip route add 1.2.3.4/32 dev $hostveth
```

We've added route for `1.2.3.4/32` through the container's veth interface
on the host.

In the container, we'd first add the routed IP address to the interface
and then set the default route via the host's address:

```bash
ip address add 1.2.3.4/32 dev eth0
ip route add 255.255.255.254/32 dev eth0
ip route add default via 255.255.255.254 dev eth0
```

You don't actually have to do any of that manually, because *osctld* manages
routes and addresses on its own. The example configuration would be created 
using *osctl* as:

```bash
osctl ct netif new routed myct01 eth0
osctl ct netif ip add myct01 eth0 1.2.3.4/32
```

[bridged veth]: veth-bridge.md
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
