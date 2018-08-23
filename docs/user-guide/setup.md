# Installing Nix
To use vpsAdminOS, you need to install [Nix]. Nix is
a functional package manager around which vpsAdminOS is built. Please follow
the [installation instructions][install-nix].

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
configuration and containers.

Once the system starts, you will be automatically logged in as root. As the
disks are empty, you need to create the zpool first.

```bash
zpool create tank mirror sda sdb
```

Next, the zpool has to be installed into *osctld*:

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
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
