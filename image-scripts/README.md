vpsAdminOS Templates
====================

This is a collection of scripts used to build container images, which are then
used by [vpsAdminOS](http://vpsadminos.org) when creating new containers.
Container image is a tarball with configuration and filesystems.

## Building imagesn
Images can be built within vpsAdminOS using `osctl-image`.

	$ osctl-image [options] <command> [arguments...]

To get a list of available images, use command `ls`:

	$ osctl-image ls

To build the selected image, use command `build`, e.g.:
	
	$ osctl-image build --build-dataset tank/image-builds alpine-3.9

## Contributing build scripts
Target images are represented by directories in [templates/](templates/). Every
template directory has to contain two files: `config.sh` and `build.sh`.
`config.sh` is used to set variables such as distribution name, version and so
on, see below. This information is used by `osctl-image`. `build.sh`
is called to actually build the image.

Shared code can be placed into [include/](include/), follow the existing naming
scheme.

### How does it work
The template build script needs to prepare the distribution's root filesystem
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

### Template name and variables
The template has to define the following variables in `config.sh`:

 - `BUILDER` - name of a builder that the image has to be built in, see below

Addional variable are optional:

 - `DISTNAME`, e.g. `debian`, `ubuntu`
 - `RELVER`, e.g. `9` for Debian or `16.04` for Ubuntu
 - `ARCH` (defaults to `x86_64`)
 - `VENDOR` (defaults to `vpsadminos`)
 - `VARIANT` (defaults to `minimal`)

If not set, `osctl-image` tries to extract the values from the image name,
which has to be in the following form:

	<DISTNAME>[-RELVER[-ARCH[-VENDOR[-VARIANT]]]]

### Builders
Templates are built in builders, which are vpsAdminOS containers. Builders
are defined in directory [builders/](builders/) by two files: `config.sh`
and `setup.sh`.

`config.sh` is similar to template configs, it specifies what distribution
and version should the builder be created from. Builders are simply containers
created from pre-existing images available in vpsAdminOS repository
at <https://templates.vpsadminos.org>, or whatever repository you have
configured on your system.

`setup.sh` is run within the builder container after it is created. This script
should installed whatever packages are needed to build images that use this
builder.
