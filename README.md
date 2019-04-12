# vpsAdminOS

vpsAdminOS is a small experimental OS for container virtualisation.

Provides environment to run unprivileged LXC containers with nesting
and AppArmor.

Based on [not-os](https://github.com/cleverca22/not-os/) - small experimental OS
for embeded situations.

It is also based on NixOS, but compiles down to a custom kernel, initrd,
and a squashfs root while reusing packages and some modules from
[nixpkgs](https://github.com/NixOS/nixpkgs/).

## Links

* IRC: #vpsadminos @ irc.freenode.net
* Documentation: <https://vpsadminos.org/>
* Man pages: <https://man.vpsadminos.org/>
* Code reference: <https://ref.vpsadminos.org/>
* ISO images: <https://iso.vpsadminos.org/>

## Technologies

- Upstream kernel with [several patches](os/packages/linux/default.nix)
- AppArmor
- LXC, LXCFS
- CRIU
- runit
- BIRD
- ZFS
- osctl/osctld (userspace tools bundled with vpsAdminOS)

## Building OS

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos

# temporarily this needs vpsadminos branch from vpsfreecz/nixpkgs

git clone https://github.com/vpsfreecz/nixpkgs --branch vpsadminos
export NIX_PATH=`pwd`

make

# to run under qemu
make qemu
```

QEMU runner creates two disk images - `sda.img` and `sdb.img` which are added
as QEMU ATA drives and can be used to create a mirrored ZFS pool which persists
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

### Nested LXC/LXD containers
Nested LXC/LXD containers can be enabled per container:

```
osctl ct set nesting <id>
```

### Docker
Docker within containers works with a modified seccomp profile:

```
osctl ct set seccomp <id> /etc/lxc/config/common.seccomp
```

Then you can install the latest Docker version within container `<id>` by
following the manual, e.g.
<https://docs.docker.com/install/linux/docker-ce/ubuntu/>.

## Building specific targets

```
nix-build -A config.system.build.tftpdir -o tftpdir
nix-build -A config.system.build.squashfs
```

## Docs

* [vpsAdminOS documentation](https://vpsadminos.org)
* [Manual pages](https://man.vpsadminos.org)
* [Reference documentation](https://ref.vpsadminos.org)
* https://linuxcontainers.org/
* http://containerops.org/2013/11/19/lxc-networking/
* http://blog.benoitblanchon.fr/lxc-unprivileged-container/

## iPXE

There is a support for generating iPXE config files, that will check
the cryptographic signature over all images, to ensure only authorized files
can run on the given hardware. This also rebuilds iPXE to contain keys to be
used for signature verification.
