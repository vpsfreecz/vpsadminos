vpsAdminOS Templates
====================

This is a collection of scripts used to build OS templates, which are then used
by [vpsAdminOS](http://vpsadminos.org) when creating new containers. OS template
is a tarball or a ZFS stream with root filesystem of various Linux distributions.

## Building templates
Templates can be built within vpsAdminOS using `osctl-template`.

	$ osctl-template [options] <command> [arguments...]

To get a list of available templates, use command `ls`:

	$ osctl-template ls

To build selected template, use command `build`, e.g.:
	
	$ osctl-template build --build-dataset tank/template-builds alpine-3.9

## Contributing build scripts
Templates are represented by directories in [templates/](templates/). Every
template directory has to contain two files: `config.sh` and `build.sh`.
`config.sh` is used to set variables such as distribution name, version and so
on, see below. This information is used by `osctl-template`. `build.sh`
is called to actually build the template.

Shared code can be placed into [include/](include/), follow the existing naming
scheme.

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

### Template name and variables
The template has define the following variable in `config.sh`:

 - `BUILDER` - name of a builder that the template has to be built in, see below

Addional variable are optional:

 - `DISTNAME`, e.g. `debian`, `ubuntu`
 - `RELVER`, e.g. `9` for Debian or `16.04` for Ubuntu
 - `ARCH` (defaults to `x86_64`)
 - `VENDOR` (defaults to `vpsadminos`)
 - `VARIANT` (defaults to `minimal`)

If not set, `osctl-template` tries to extract the values from the template name,
which has to be in the following form:

	<DISTNAME>[-RELVER[-ARCH[-VENDOR[-VARIANT]]]]

### Builders
Templates are built in builders, which are vpsAdminOS containers. Builders
are defined in directory [builders/](builders/) by two files: `config.sh`
and `setup.sh`.

`config.sh` is similar to template configs, it specifies what distribution
and version should the builder be created from. Builders are simply containers
created from pre-existing templates available in vpsAdminOS repository
at <https://templates.vpsadminos.org>, or whatever repository you have
configured on your system.

`setup.sh` is run within the builder container after it is created. This script
should installed whatever packages are needed to build templates that use this
builder.
