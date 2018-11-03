# Snappy
[Snappy] is a software deployment and package management system designed by
Canonical that can be used to install the same packages on various
distributions. Snaps work in vpsAdminOS containers with some extra configuration.

To run snap in a container, it has to have access to FUSE:

```
osctl ct devices add <id> char 10 229 rwm /dev/fuse
```

Install [squashfuse], e.g. for Ubuntu containers:

```
ct exec <id> apt install fuse squashfuse
```

Also make sure that you have directory `/lib/modules`:

```
ct exec <id> mkdir -p /lib/modules
```

Now you can [install] and [use] snapd inside the container.

[Snappy]: https://snapcraft.io
[squashfuse]: https://github.com/vasi/squashfuse
[install]: https://docs.snapcraft.io/installing-snapd/
[use]: https://docs.snapcraft.io/getting-started/
