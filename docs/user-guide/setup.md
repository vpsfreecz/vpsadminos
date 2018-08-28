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
terminal. By default, the OS creates a file on disk which is used as disk device
for zpool called `tank` within the virtual machine. The zpool is used to store
configuration and containers.

On the first boot, the zpool will be automatically created and installed into
*osctld*. You can use your own zpools, simply use `zpool create <name>` and
then `osctl pool install <name>`.

*osctld* will create several ZFS datasets and will generally assume that no one
else is using the zpool. For more complicated use-cases, it is possible to scope
*osctld* to a subdataset, see [man osctl].

When you have at least one zpool imported and installed, you can proceed
to [user](users.md) and [container](containers.md) management.

[Nix]: https://nixos.org/nix/
[install-nix]: https://nixos.org/nixpkgs/
[nixpkgs]: https://nixos.org/nixpkgs/
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html
