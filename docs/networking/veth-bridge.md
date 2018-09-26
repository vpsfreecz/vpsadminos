# Bridged veth
Bridged veth is a network interface given to a container which is linked
to some other network interface on the host. *osctld* expects DHCP server
to be running on the linked interface, so that containers are assigned IP
addresses dynamically.

Virtual machines run with `make qemu` have `lxcbr0` preconfigured. To enable
`lxcbr0` in other configurations, set option `networking.lxcbr = true;`,
e.g. in your `config/local.nix`.

To create a bridged veth, use:

```bash
osctl ct netif new bridge --link lxcbr0 myct01 eth0
```

If you wish to assign static IP addresses, you can set static MAC addresses
for container interfaces and use a MAC filter in the DHCP server. Another option
is to disable DHCP altogether and configure the interface statically.

To create an interface without DHCP, use the `--no-dhcp` switch:

```bash
osctl ct netif new bridge --link lxcbr0 --no-dhcp myct01 eth0
```

DHCP can also be toggled on an already existing interface:

```bash
osctl ct netif set --enable-dhcp|--disable-dhcp myct01 eth0
```

When DHCP is disabled, you can manage IP addresses statically using
`osctl ct netif ip` commands.
