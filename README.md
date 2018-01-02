# vpsadminOS

vpsadminOS is a small experimental OS for virtualisation purposes.

Provides environment to run unprivileged lxc containers with nesting and apparmor.

Based on [not-os](https://github.com/cleverca22/not-os/) - small experimental OS for embeded situations.

It is also based on NixOS, but compiles down to a custom kernel, initrd, and a squashfs root while
reusing packages and some modules from [nixpkgs](https://github.com/NixOS/nixpkgs/).

## Technologies

- kernel
- apparmor
- lxc, lxcfs
- criu
- runit
- bird

## Building OS

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos

# temporarily this needs vpsadminos branch from sorki/nixpkgs

git clone https://github.com/sorki/nixpkgs --branch vpsadminos
export NIX_PATH=`pwd`

make

# to run under qemu
make qemu
```

## Building osctl/osctld
`$NIX_PATH` must be exported and contain `nixpkgs`. osctl and osctld are
installed as gems. By default, the gems are pushed and installed from
`https://rubygems.vpsfree.cz`. Pushing requires authentication. Rake, bundler
and bundix must be installed.

```bash
gem install geminabox
gem inabox -c

# Build and push gems
make gems

# Rebuild OS with updated gems
make
```

## Usage

```bash
# Login via ssh or use qemu terminal with autologin
ssh -p 2222 localhost

# Create a zpool:
dd if=/dev/zero of=/tank.zpool bs=1M count=4096 && zpool create tank /tank.zpool

# Configure osctld:
osctl pool install tank

# Fetch OS templates:
wget https://s.hvfn.cz/~aither/pub/tmp/templates/ubuntu-16.04-x86_64-vpsfree.tar.gz
wget https://s.hvfn.cz/~aither/pub/tmp/templates/debian-9-x86_64-vpsfree.tar.gz
wget https://s.hvfn.cz/~aither/pub/tmp/templates/centos-7.3-x86_64-vpsfree.tar.gz
wget https://s.hvfn.cz/~aither/pub/tmp/templates/alpine-3.6-x86_64-vpsfree.tar.gz

# Create a user:
osctl user new --ugid 5000 --offset 666000 --size 65536 myuser01

# Create a container:
osctl ct new --user myuser01 --template ubuntu-16.04-x86_64-vpsfree.tar.gz myct01

# Configure container networking:
# Bridged veth
osctl ct netif new bridge --link lxcbr0 myct01 eth0

# Routed veth
osctl ct netif new routed --via 10.100.10.100/30 myct01 eth1
osctl ct netif ip add myct01 eth1 1.2.3.4/32

# Start the container:
osctl ct start myct01

# Work with containers:
osctl ct ls
osctl ct attach myct01
osctl ct console myct01
osctl ct exec myct01 ip addr

# Further information:
osctl help user
osctl help ct

# Profit
```

### Nested containers

To allow nesting, you need to explicitly configure it per container:

```
osctl ct set nesting <id> enabled/disabled
```

## Building specific targets:

```
nix-build -A config.system.build.tftpdir -o tftpdir
nix-build -A config.system.build.squashfs
```

## Docs:

* https://linuxcontainers.org/
* http://containerops.org/2013/11/19/lxc-networking/
* http://blog.benoitblanchon.fr/lxc-unprivileged-container/

## iPXE

There is a support for generating iPXE config files, that will check the cryptographic signature over all images, to ensure only authorized files can run on the given hardware.
This also rebuilds iPXE to contain keys to be used for signature verification.
