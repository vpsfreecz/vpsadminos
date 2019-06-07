# Container images
New containers are usually created from images. An image is a tar archive with
configuration and the container filesystems, see the full
[specification](../specifications/container-image.md).

When creating a new container, the user selects the image to be used.
Images can be downloaded from remote repositories or files from the local
filesystem can be used.

Images are described by several parameters:

 - *vendor* - the image provider, e.g. `vpsadminos`
 - *variant* - content description, e.g. `minimal`
 - *arch* - `x86_64`, `x86` and so on
 - *distribution* - `debian`, `ubuntu` and so on
 - *version* - distribution version

To create a new container, *osctld* needs to know *arch*, *distribution*
and *version*. *vendor* and *variant* are used just to describe the image,
*osctld* is not using these parameters.

# Using remote images
Command `osctl ct new` is used to create containers from images downloaded from
remote repositories.

## Available images
Images from remote repositories can be listed with `osctl repo images ls`:

```shell
[root@vpsadminos:~]# osctl repo images ls default
VENDOR       VARIANT   ARCH     DISTRIBUTION   VERSION               TAGS                                      CACHED
vpsadminos   minimal   x86_64   alpine         3.8                   -                                         -
vpsadminos   minimal   x86_64   alpine         3.9                   latest,stable                             -
vpsadminos   minimal   x86_64   arch           20190605              latest,stable                             -
vpsadminos   minimal   x86_64   centos         6                     -                                         -
vpsadminos   minimal   x86_64   centos         7                     latest,stable                             -
vpsadminos   minimal   x86_64   debian         8                     -                                         -
vpsadminos   minimal   x86_64   debian         9                     latest,stable                             -
vpsadminos   minimal   x86_64   devuan         2.0                   latest,stable                             -
vpsadminos   minimal   x86_64   fedora         29                    -                                         -
vpsadminos   minimal   x86_64   fedora         30                    latest,stable                             -
vpsadminos   minimal   x86_64   gentoo         20190605              latest,stable                             -
vpsadminos   minimal   x86_64   nixos          19.03                 latest,stable                             -
vpsadminos   minimal   x86_64   nixos          unstable-20190605     unstable                                  -
vpsadminos   minimal   x86_64   opensuse       leap-15.1             latest,stable                             -
vpsadminos   minimal   x86_64   opensuse       tumbleweed-20190605   -                                         -
vpsadminos   minimal   x86_64   slackware      14.2                  latest,stable                             -
vpsadminos   minimal   x86_64   ubuntu         16.04                 -                                         -
vpsadminos   minimal   x86_64   ubuntu         18.04                 latest,stable                             -
vpsadminos   minimal   x86_64   void           glibc-20190605        latest,latest-glibc,stable,stable-glibc   -
vpsadminos   minimal   x86_64   void           musl-20190605         latest-musl,stable-musl                   -
```

## Examples
`osctl ct new` requires at least option `--distribution`, other parameters are
optional. Unless `--version` is set, tag `stable` is used. `--arch` defaults
to the host's architecture and the default vendor and variant as reported by
the repository is used.

```shell
osctl ct new --distribution ubuntu myct01
```

With specific version:

```shell
osctl ct new --distribution debian --version 9 myct01
```

# Using local images
To use images from local files, use command `osctl ct import`:

```shell
osctl ct import my-image.tar
```

If the image does not contain container ID, or if you wish to change it, use
option `--as-id`:

```shell
osctl ct import --as-id myct01 my-image.tar
```

For more information, see [container export/import](../containers/export-import.md) and
how to [build images](../container-images/creating.md).
