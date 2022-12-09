# Development
When developing *osctl*, *osctld* or other components, it is necessary to have
a fast way to change the code and see the results. The standard deployment
process forces you to build all gems, even those without changes, push the gems
to rubygems repository, then build the OS, boot it and finally test the program.
Rinse and repeat.

To make the process faster, there is a way to mount the source codes into the OS
running within VM. All components have a `default.nix` file, which makes it
possible to use `nix-shell` to automatically setup the environment in which you
can test the changed code immediately.

While this text assumes you're developing in a VM run with `make qemu`, you can
use this method to develop on any machine running vpsAdminOS. The difference
would be only in how you make the source codes available, e.g. mount over NFS
or clone the git repository locally.

## Configuration
To make the source codes available in the VM, you have to configure qemu to
share those directories and then mount them within the VM. For `nix-shell` to
work, you also need to mount *nixpkgs* from the host. Change your
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
$ export NIX_PATH=/where/is/your/nix/path
$ sudo -E make qemu
```

## Entering the development environment
For example, to work on *osctl*, you can:

```shell
$ ssh -p 2222 root@localhost

[root@vpsadminos:~]# cd /mnt/vpsadminos/osctl

[root@vpsadminos:/mnt/vpsadminos/osctl]# nix-shell
[... nix-shell setup ...]
[... bundle setup ...]

[nix-shell:/mnt/vpsadminos/osctl]$ which osctl
/tmp/dev-ruby-gems/bin/osctl
```

Edit sources on the host, then launch *osctl* within the `nix-shell` in the VM
and the changed code will be run.

If you'd like to work on *osctld*, you'll need to stop it as a system service
first:

```shell
$ sv stop osctld
```

Then you can start it from the source code:

```shell
[root@vpsadminos:~]# cd /mnt/vpsadminos/osctld

[root@vpsadminos:/mnt/vpsadminos/osctld]# nix-shell
[... nix-shell setup ...]
[... bundle setup ...]

[nix-shell:/mnt/vpsadminos/osctld]$ run-osctld
```

## Deployment
When you have your work finished and want to commit, you need to build gems
and deploy them to the rubygems repository. CI and other people will then be
able to build the OS with your changes, without the need to setup the development
environment themselves.

By default, the gems are pushed and installed from <https://rubygems.vpsfree.cz>.
Pushing requires authentication, you'll have to ask for credentials.
Use `nix-shell` to enter a prepared environment.

```shell
# Configure remote repository for geminabox
$ gem inabox -c
```

Within `nix-shell`, you can use `make` to build gems and the OS:

```shell
# Build and push gems
$ make gems

# Rebuild OS with updated gems
$ make
```

Now you can commit and make a pull request.
