# vpsAdminOS

vpsAdminOS is a small OS serving as a host for unprivileged Linux system
containers. It is based on [not-os](https://github.com/cleverca22/not-os/)
and [NixOS](https://nixos.org). It is designed to run full distributions inside
unprivileged containers which look and feel as much as a virtual machine
as possible.

vpsAdminOS is developed and used in production by [vpsFree.cz](https://vpsfree.cz),
a non-profit organization which provides virtual servers to its members.
See [vpsfree-cz-configuration](https://github.com/vpsfreecz/vpsfree-cz-configuration)
for example cluster configuration.

## Links

* IRC: #vpsadminos @ irc.libera.chat
* Documentation: <https://vpsadminos.org/>
* Man pages: <https://man.vpsadminos.org/>
* OS and program references: <https://ref.vpsadminos.org/>
* ISO images: <https://iso.vpsadminos.org/>

## Components

vpsAdminOS uses:

- [LTS kernel with a mix of out-of-tree patches](https://github.com/vpsfreecz/linux)
  to improve container experience,
- runit as an init system,
- ZFS for storage,
- our own tools for system container management called [osctl](https://man.vpsadminos.org/man8/osctl.8.html),
- LXC is used to run the containers,
- AppArmor for additional security,
- BIRD for network routing.

## Building OS

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos
```

vpsAdminOS is developed on top of the latest NixOS release, so make sure that
the correct version of nixpkgs is in `NIX_PATH`, or set it as follows:

```bash
git clone https://github.com/NixOS/nixpkgs --branch nixos-21.11
export NIX_PATH=`pwd`
```

vpsAdminOS can now be built and run:

```
# Build the OS
make

# Run under qemu
make qemu
```

The QEMU runner creates two disk images - `sda.img` and `sdb.img` which are added
as QEMU ATA drives and can be used to create a mirrored ZFS pool that persists
across reboots.

## Usage

```bash
# Login via ssh or use qemu terminal with autologin
ssh -p 2222 localhost

# Configure osctld:
osctl pool install tank

# Create a container:
osctl ct new --distribution alpine myct01

# Configure container networking:
# Bridged veth
osctl ct netif new bridge --link lxcbr0 myct01 eth0

# Routed veth
osctl ct netif new routed myct01 eth1
osctl ct netif ip add myct01 eth1 1.2.3.4/32

# Start the container:
osctl ct start myct01

# Work with containers:
osctl ct ls
osctl ct attach myct01
osctl ct console myct01
osctl ct exec myct01 ip addr

# More information:
man osctl

# https://vpsadminos.org/user-guide/setup/
# https://vpsadminos.org/containers/administration/
```

### Converting OpenVZ Legacy containers into vpsAdminOS
[vpsAdminOS Converter](converter) can be used to convert OpenVZ Legacy
containers containers into vpsAdminOS. See the
[documentation](https://vpsadminos.org/migration-paths/converter/).

### Nested containers
vpsAdminOS supports nested containers, e.g. LXC/LXD or Docker.

Nesting LXC/LXD containers can be enabled per container using:

```
osctl ct set nesting <id>
```

Docker works out-of-the-box with several
[known issues](https://vpsadminos.org/services/docker/#known-issues).

## Docs

* [vpsAdminOS documentation](https://vpsadminos.org)
* [Manual pages](https://man.vpsadminos.org)
* [Reference documentation](https://ref.vpsadminos.org)
* https://linuxcontainers.org/
