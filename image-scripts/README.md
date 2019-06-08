vpsAdminOS Image Build Scripts
==============================

This is a collection of scripts used to build and test container images, which
are then used by [vpsAdminOS](http://vpsadminos.org) when creating new containers.
Container image is a tarball with configuration and filesystems, see the
[specification](https://vpsadminos.org/specifications/container-image/). More
information about container images can be found in the
[documentation](https://vpsadminos.org/container-images/usage/).

## Building images
Images can be built within vpsAdminOS using `osctl-image`. `osctl-image` needs
the build scripts in its current working directory.

```shell
git clone -b vpsadminos git@github.com:vpsfreecz/build-vpsfree-templates.git
cd build-vpsfree-templates
```

Usage:

```shell
osctl-image --help
NAME
    osctl-image - Build, test and deploy vpsAdminOS images

SYNOPSIS
    osctl-image [global options] command [command options] [arguments...]

VERSION
    19.03.0

GLOBAL OPTIONS
    --help    - Show this message
    --version - Display the program version

COMMANDS
    build       - Build image
    ct          - Manage build and test containers
    deploy      - Build image, test it and deploy to repository
    help        - Shows a list of commands or help for one command
    instantiate - Build the image and use it in a container
    ls          - List available images
    test        - Test image
```

To get a list of available images, use:

```shell
osctl-image ls
```

`osctl-image` requires a dedicated ZFS dataset which is used for building
images. The dataset should not have any data or subdatasets that you care about.

```shell
zfs create tank/image-builds
```

To build an image, use command `osclt-image build`, e.g.:

```shell
osctl-image build --build-dataset tank/image-builds alpine-3.9
```

Tests can be run as:

```shell
osctl-image test --build-dataset tank/image-builds alpine-3.9
```

Images can be also tested manually in container. Use command
`osctl-image instantiate` to create one:

```shell
osctl-image instantiate --build-dataset tank/image-builds alpine-3.9
```

Managed containers can be listed using command `osctl-image ct ls` and cleaned
up using `osctl-image ct del`. See
[man osctl-image(8)](https://man.vpsadminos.org/osctl-image/man8/osctl-image.8.html)
for more information.

## Contributing build scripts
Target images are represented by directories in [images/](images/). Every
image directory has to contain two files: `config.sh` and `build.sh`.
`config.sh` is used to set variables such as distribution name, version and so
on, see below. This information is used by `osctl-image`. `build.sh`
is called to actually build the image.

Shared code can be placed into [include/](include/), follow the existing naming
scheme.

### How does it work
The image build script needs to prepare the distribution's root filesystem
in directory stored in variable `$INSTALL`. The script can download arbitrary
assets into directory `$DOWNLOAD`. When the script finishes, the `$INSTALL`
directory should contain the root filesystem, i.e. directories like `bin`, `usr`,
`var`, `home` and so on.

The build script can generate configuration script, that will be executed
as chrooted within the `$INSTALL` directory. Function `configure-append` is used
to append chunks of the configuration script and `run-configure` will chroot
to the `$INSTALL` directory and run it. This is where you can use the
distribution's package manager and other programs.

For example, to create a Debian image, you would use `debootstrap` to download
the base root file system, then use the configuration script to install additional
packages and configure the services.

### Image name and variables
The image has to define the following variables in `config.sh`:

 - `BUILDER` - name of a builder that the image has to be built in, see below

Additional variables are optional:

 - `DISTNAME`, e.g. `debian`, `ubuntu`
 - `RELVER`, e.g. `9` for Debian or `16.04` for Ubuntu
 - `ARCH` (defaults to `x86_64`)
 - `VENDOR` (defaults to `vpsadminos`)
 - `VARIANT` (defaults to `minimal`)

If not set, `osctl-image` tries to extract the values from the image name,
which should be in the following form:

	<DISTNAME>[-RELVER[-ARCH[-VENDOR[-VARIANT]]]]

### Builders
Images are built in builders, which are vpsAdminOS containers. Builders
are defined in directory [builders/](builders/) by two files: `config.sh`
and `setup.sh`.

`config.sh` is similar to image configs, it specifies what distribution
and version should the builder be created from. Builders are simply containers
created from pre-existing images available in vpsAdminOS repository
at <https://images.vpsadminos.org>, or whatever repository you have
configured on your system.

`setup.sh` is run within the builder container after it is created. This script
should installed whatever packages are needed to build images that use this
builder.
