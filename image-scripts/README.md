vpsAdminOS Templates
====================

This is a collection of scripts used to build OS templates, which are then used
by [vpsAdminOS](http://vpsadminos.org) when creating new containers. OS template
is a tarball or a ZFS stream with root filesystem of various Linux distributions.

## Building templates
Templates can be built using script `bin/build-vpsadminos-templates`.

	$ bin/build-vpsadminos-templates [options] all|<templates...>

To get a list of available templates, call the script without any argument or
with option `-h`, `--help`.

The script needs to be given path to a build directory or ZFS dataset, where
the templates will be prepared.

With build directory:

	$ bin/build-vpsadminos-templates --build-dir /tmp/build debian-9

With build dataset:

	$ bin/build-vpsadminos-templates --build-dataset tank/tmp/build debian-9

Build dataset is needed when you wish to get the template also as a ZFS stream,
in addition to tar archive.

By default, the templates are stored in the current directory, but it can be
changed with option `--output-dir`:

	$ bin/build-vpsadminos-templates --build-dataset tank/tmp/build \
	                                 --output-dir /var/www/release \
	                                 debian-9

## Contributing build scripts
Templates are placed in directory [templates/](templates/), shared code can be
placed into [include/](include/), follow the existing naming scheme.

### How does it work
The template script needs to prepare the distribution's root filesystem
in directory stored in variable `$INSTALL`. The script can download arbitrary
assets into directory `$DOWNLOAD`. When the script finishes, the `$INSTALL`
directory should contain the root filesystem, i.e. directories like `bin`, `usr`,
`var`, `home` and so on.

The template script can generate configuration script, that will be executed
as chrooted within the `$INSTALL` directory. Function `configure-append` is used
to append chunks of the configuration script and `run-configure` will chroot
to the `$INSTALL` directory and run it. This is where you can use the
distribution's package manager and other programs.

For example, to create a Debian template, you would use `debootstrap` to download
the base root file system, then use the configuration script to install additional
packages and configure the services.

### Variables
The template has to define the following variables:

 - `DISTNAME`, e.g. `debian`, `ubuntu`
 - `RELVER`, e.g. `9` for Debian or `16.04` for Ubuntu

Optional variables are:

 - `ARCH` (defaults to `x86_64`)
 - `EXTRAVER`
 - `OUTPUT_SUFFIX`

The variables are then used to create the template name.

## Architecture
For each template to be built, `bin/build-vpsadminos-templates` is calling
internal build script `bin/builder`. The builder is given necessary configuration,
set's up the environment and calls the template script. Variables defined by
the template script are given back to `bin/build-vpsadminos-templates` as files
in the builder's output directory.
