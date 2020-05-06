# Installing Nix
To use vpsAdminOS, you need to install [Nix]. Nix is
a functional package manager around which vpsAdminOS is built. Please follow
the [installation instructions][install-nix].

# Downloading vpsAdminOS
Clone the git repository of vpsAdminOS:

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos
```

vpsAdminOS is developed on top of the latest NixOS release, so make sure that
the correct version of nixpkgs is in `NIX_PATH`, or set it as follows:

```bash
git clone https://github.com/NixOS/nixpkgs-channels --branch nixos-20.03
export NIX_PATH=`pwd`
```

# Building the OS
The easiest way to try vpsAdminOS is to run it in virtual machine using QEMU:

```bash
make qemu
```

For the first time, the build can take a long time, because it has to compile
the kernel and ZFS.

# Setup
When the build finishes, a virtual machine is started, its console is in your
terminal. By default, the OS creates a file on disk which is used as disk device
for zpool called `tank` within the virtual machine. The zpool is used to store
configuration and containers.

On the first boot, the pool will be automatically created and installed into
*osctld*.

*osctld* will create several ZFS datasets and will generally assume that no one
else is using the zpool. For more complicated use-cases, it is possible to scope
*osctld* to a subdataset, see [man osctl].

When you have at least one zpool imported and installed, you can proceed
to [container](containers.md) management.

[Nix]: https://nixos.org/nix/
[install-nix]: https://nixos.org/nix/download.html
[nixpkgs]: https://nixos.org/nixpkgs/
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
