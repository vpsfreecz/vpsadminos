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

## Building

```bash
git clone https://github.com/vpsfreecz/vpsadminos/

# temporarily this needs vpsadminos branch from sorki/nixpkgs

git clone https://github.com/sorki/nixpkgs --branch vpsadminos
export NIX_PATH=`pwd`

cd vpsadminos
make

# to run under qemu
make qemu
```

## Usage

```bash
# login via ssh or use qemu terminal with autologin
ssh -p 2222 localhost

# switch to lxc user
su - lxc

# create container
lxc-create -n ct_ubuntu -t download -- -d ubuntu -r zesty -a amd64

# start container
lxc-start -n ct_ubuntu

# verify
lxc-ls -f

# profit
```

### Nested containers

To allow nesting, you need to edit containers `config` file
and uncomment `nesting.conf` include line following this line:

```
# Uncomment the following line to support nesting containers:
# include = ...
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
