# Development
When developing *osctl*, *osctld* or other components, it is necessary to have
a fast way to change the code and see the results. The standard deployment
process still requires rebuilding the OS, booting it and testing the changed
program. For development, the daemon and tools can be run directly from the
source tree without rebuilding the OS after every change.

To do that, mount the source tree into the OS running within a VM. The
repository flake exports development shells for the individual components,
which makes it possible to use `nix develop` to
automatically set up the environment in which you can test the changed code
immediately.

First-party Ruby components are packaged from sources in this repository and
from flake inputs. They are not uploaded to a RubyGems repository and do not use
build IDs; the source commit identifies the build.

While this text assumes you're developing in a VM run with `make qemu`, you can
use this method to develop on any machine running vpsAdminOS. The difference
would be only in how you make the source tree available, e.g. mount over NFS
or clone the git repository locally.

## Configuration
To make the source tree available in the VM, you have to configure qemu to
share those directories and then mount them within the VM. For `nix develop` to
work, you also need to mount the vpsAdminOS repository from the host. Change your
`os/configs/local.nix` to include `os/configs/devel.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    ./devel.nix
  ];

  ...
}
```

## Building and starting the VM
The OS will need read-write access to the sources. This is rather unfortunate,
but bundler tries to create some temporary files and fails if the directory is
read-only. This means that qemu has to be run as root, in order to have access
to your files:

```shell
$ sudo -E make qemu
```

## Entering the development environment
For example, to work on *osctl*, you can:

```shell
$ ssh -p 2222 root@localhost

[root@vpsadminos:~]# cd /mnt/vpsadminos/osctl

[root@vpsadminos:/mnt/vpsadminos/osctl]# nix develop ..#osctl
[... nix develop setup ...]
[... bundle setup ...]

(dev:osctl) [root@vpsadminos:/mnt/vpsadminos/osctl]# which osctl
/tmp/dev-ruby-gems/bin/osctl
```

Edit sources on the host, then launch *osctl* within the `nix develop` shell in
the VM and the changed code will be run.

If you'd like to work on *osctld*, you'll need to stop it as a system service
first:

```shell
$ sv stop osctld
```

Then you can start it from the source code:

```shell
[root@vpsadminos:~]# cd /mnt/vpsadminos/osctld

[root@vpsadminos:/mnt/vpsadminos/osctld]# nix develop ..#osctld
[... nix develop setup ...]
[... bundle setup ...]

(dev:osctld) [root@vpsadminos:/mnt/vpsadminos/osctld]# run-osctld
```

## Deployment
When your change affects packaged Ruby components or their dependencies, refresh
the packaged gem metadata before committing. The metadata lives in
`os/packages/*/Gemfile`, `os/packages/*/Gemfile.lock` and
`os/packages/*/gemset.nix`. It records third-party gem dependencies and points
first-party gems at sources in this repository and at flake inputs such as
`netlinkrb` and `ruby-lxc`.

Within `nix develop`, refresh metadata and rebuild the OS:

```shell
# Refresh packaged gem metadata
$ make gems

# Rebuild the OS with updated package definitions
$ make
```

For a focused update, use the package target directly, e.g. `make osctld` or
`make osctl`. If `make gems` changes only packaged gem metadata, keep those
changes in a separate generated commit using `make commit-gems`, or update an
existing generated metadata commit with `make amend-gems`.

If the refresh produces no diff, there is no gem metadata to commit. In all
cases, no build IDs are created and no first-party gems are pushed to a remote
RubyGems repository.
