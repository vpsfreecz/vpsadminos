# Installation

Although vpsAdminOS is meant to be run from memory, it is also possible
to install it on a hard drive or flash drive. This is useful for storage
nodes that will act as netboot servers for the rest of the nodes
or as a an option to run without netboot at all.

vpsAdminOS provides `os-generate-config` and `os-install` tools
similar to `nixos-generate-config` and `nixos-install`.

Installation requires manual partitioning using e.g. `fdisk`. If your
installation device is `/dev/sda`, you can create a single partition `/dev/sda1`
and mount it to `/mnt`. 

Configs can be generated using

```bash
os-generate-config --root /mnt
```

In `/mnt/vpsadminos/configuration.nix` make sure to set `boot.loader.grub.device` option to
point to drive where GRUB should be installed. You can also set `boot.loader.grub.devices`
to install GRUB to multiple devices.

You can also configure your [ZFS pools](pools.md) at this point.

After adjustments of generated configs in `/mnt/vpsadminos/` OS can be installed using

```bash
os-install --root /mnt
```

After setting the password your installation is completed and you can reboot your machine.
Further changes to your installation can be performed by editing configs in `/etc/vpsadminos/`
and running `os-rebuild switch`.

## Chroot

If you need to chroot into vpsAdminOS installation use `os-enter` utility - if your installation
is mounted at `/mnt` you can chroot into it by running:

```bash
os-enter /mnt
```
