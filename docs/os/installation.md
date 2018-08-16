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
os-generate-config --root=/mnt
```

After adjustments of generated configs in `/mnt/vpsadminos/` OS can beinstalled using

``bash
os-install --root=/mnt
```
