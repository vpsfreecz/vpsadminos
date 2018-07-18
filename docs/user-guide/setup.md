# Installing Nix
To use vpsAdminOS, you need to install [Nix]. Nix is
a functional package manager around which vpsAdminOS is built. Please follow
the [installation instructions][install-nix].

For the purposes of this user guide, you don't need to be familiar with Nix
and NixOS, but it certainly helps. It's also good know the basics of ZFS -- e.g.
what is a zpool, dataset, or a snapshot. To use vpsAdminOS in production, you
definitely need to know how to use [Nix] with [nixpkgs], [NixOS] and most likely
[NixOps] as well.

# Downloading vpsAdminOS
Clone the git repositories of vpsAdminOS and our version of nixpkgs:

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos
git clone https://github.com/vpsfreecz/nixpkgs --branch vpsadminos
```

# Building the OS
The easiest way to try vpsAdminOS is to run it in virtual machine using QEMU.
Before you can build the OS, you need to tell Nix to use our custom version
of nixpkgs. Make sure that you're within the cloned `vpsadminos` repository.

```bash
export NIX_PATH="`pwd`"
```

Now you can build and run the OS using `make`:

```bash
make qemu
```

For the first time, the build will take at least an hour, because it has to
compile the kernel and ZFS.

# Setup
When the build finishes, a virtual machine is started, its console is in your
terminal. The OS creates two files on disk which are used as disk devices for
a zpool within the virtual matchine. The zpool will be used to store
configuration and containers. On the first run, the disks are unitilized, so you
will see the following message:

```
An error occurred in stage 1 of the boot process, which must import the
ZFS pool and then start stage 2. Press one
of the following keys:

  i) to launch an interactive shell
  n) to create pool with "zpool create tank mirror sda sdb"
  r) to reboot immediately
  *) to ignore the error and continue
```

Choose `n` and hit enter to create the zpool. On the following boots, the zpool
will be automatically imported.

The system should continue to boot and log you in as root. With the system
booted and zpool created, *osctld* has to be configured to use the zpool:

```bash
osctl pool install tank
```

`osctl pool install` will mark the pool so that *osctld* will always import it
on start. All configuration and data is stored on installed zpools, the rest
of the system is not persistent between reboots. `osctl pool install` will also
automatically import the pool into *osctld*, so that you can immediately use it.

*osctld* will create several ZFS datasets and will generally assume that no one
else is using the zpool. For more complicated use-cases, it is possible to scope
*osctld* to a subdataset, see [man osctl].

When you have at least one zpool imported and installed, you can proceed
to [user](users.md) and [container](containers.md) management.

[Nix]: https://nixos.org/nix/
[install-nix]: https://nixos.org/nixpkgs/
[nixpkgs]: https://nixos.org/nixpkgs/
[NixOs]: https://nixos.org/
[NixOps]: https://nixos.org/nixops/
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
