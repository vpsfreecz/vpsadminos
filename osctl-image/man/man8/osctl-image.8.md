# osctl-image 8                2020-05-06                             19.03.0

## NAME
`osctl-image` - build, test and deploy vpsAdminOS container images

## SYNOPSIS
`osctl-image` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osctl-image` manages containers that serve as builders and uses them to
build container images. `osctl-image` itself does not know how to build
images. It is concerned with managing build containers, executing arbitrary
builds and testing resulting images.

`osctl-image` has to be used in conjuction with program or programs that know
how to build specific distribution images. vpsAdminOS comes with one such
collection of image building scripts:
<https://github.com/vpsfreecz/build-vpsfree-images/tree/branch/vpsadminos>.

See `IMAGE BUILDER INTERFACE` for more information about the interaction
of `osctl-image` with image building programs.

## COMMANDS
`ls` [*options*]
  List available images.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`build` [*options*] `all`|*image*[`,`*image...*]
  Build selected images.

    `--build-dataset` *dataset*
      Name of a ZFS filesystem which can be used to build images. Required.

    `--output-dir` *dir*
      Directory where the resulting images are stored. Defaults to `./output`.

    `--vendor` *vendor*
      Override vendor attribute defined by the image.

    `--jobs` *n*
      How many image should be built in parallel. Defaults to `1`.

`test` [*options*] `all`|*image*[`,`*image...*] [*test*[`,`*test...*]]
  Run one or more tests on all or selected images. If the image is not
  found in the output directory, it is built, otherwise a cached version is
  used. Rebuild can be forced using option `--rebuild`.

    `--build-dataset` *dataset*
      Name of a ZFS filesystem which can be used to build images. Required.

    `--output-dir` *dir*
      Directory where the resulting images are stored. Defaults to `./output`.

    `--vendor` *vendor*
      Override vendor attribute defined by the image.

    `--rebuild`
      Rebuild the image even if it is found in the output directory.

    `--keep-failed`
      Keep containers from failed tests.

`instantiate` [*options*] *image*
  Create a container from the build image. If the image is not found in
  the output directory, it is built, otherwise a cached version is used. Rebuild
  can be forced using option `--rebuild`.

    `--build-dataset` *dataset*
      Name of a ZFS filesystem which can be used to build images. Required.

    `--output-dir` *dir*
      Directory where the resulting images are stored. Defaults to `./output`.

    `--vendor` *vendor*
      Override vendor attribute defined by the image.

    `--rebuild`
      Rebuild the image even if it is found in the output directory.

    `--container` *ctid*
      Do not create a new container, but reinstall container *ctid* to
      *image*. Configuration of the existing container is kept.

`deploy` [*options*] *image*[`,`*image...*] *repository*
  Build, test and deploy images to *repository*. Images are build only
  if they aren't found in the output directory, or `--rebuild` is used.
  *repository* is a directory managed by `osctl-repo`.

    `--build-dataset` *dataset*
      Name of a ZFS filesystem which can be used to build images. Required.

    `--output-dir` *dir*
      Directory where the resulting images are stored. Defaults to `./output`.

    `--vendor` *vendor*
      Override vendor attribute defined by the image.

    `--tag` *tag*
      Tag the image within the repository. Tags can be used to access the
      image instead of using its version. Used tags include `stable`, `latest`
      and `testing`.

    `--jobs` *n*
      How many image should be built in parallel. Defaults to `1`.

    `--rebuild`
      Rebuild the image even if it is found in the output directory.

    `--keep-failed`
      Keep containers from failed tests.

    `--skip-tests`
      Do not run tests, deploy images immediately after build.

`ct ls` [*options*]
  List managed build-related containers.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`ct del` [*options*] [*ctid*...]
  Delete selected managed containers.

    `--type` `builder`|`test`|`instance`
      Delete only containers of selected type.

    `-f`, `--force`
      Do not ask for confirmation, delete the containers right away.

## IMAGE BUILDER INTERFACE
Image building programs define builders and actual images to be built.
Builders are simply containers, in which the images are then built.

`osctl-image` requires three executable files in the current working
directory: `bin/config`, `bin/runner` and `bin/test`.

`bin/config` is used to gather information about builders and images. It is
called from the vpsAdminOS host.

`bin/runner` is used to either setup builders or build images. It is called
within build containers managed by `osctl-image`.

`bin/test` is used to test built images. It is run on the vpsAdminOS host
and can use `osctl` to test containers managed by `osctl-image`. Since
the tests may require additional programs, `bin/test` is invoked by a `nix-shell`
operating on `./shell-test.nix`. You can configure your dependencies in this Nix
file.

All executables have to implement argument-based commands described below.

### bin/config interface
`bin/config builder list`
  List available builders, one per line.

`bin/config builder show` *name*
  Show builder attributes, one per line, `<attribute>=<value>`.

`bin/config image list`
  List available images, one per line.

`bin/config image show` *name*
  Show image attributes, one per line, `<attribute>=<value>`.

### bin/runner interface
`bin/runner builder setup` *name*
  Setup build container, i.e. install required packages.

`bin/runner` image build *build-id* *work-dir* *install-dir* *name*
  Build image *name* to directory *install-dir*. Temporary files can be
  saved to *work-dir*. *build-id* should be used when creating temporary
  directories or files as a unique identifier. Custom container config can be
  placed at *install-dir*`/container.yml`.

### bin/test interface
`bin/test image run` *image* *test* *ctid*
  Run *test* on container *ctid*, which is an instance of *image*. The test is
  considered successful when the programs exits with `0`.

### Builder attributes

 - `DISTNAME`
 - `RELVER`
 - `ARCH`
 - `VENDOR`
 - `VARIANT`

### Image attributes

 - `BUILDER`
 - `DISTNAME`
 - `RELVER`
 - `ARCH`
 - `VENDOR`
 - `VARIANT`

Only `BUILDER` is required. Other attributes can be passed within the image
name in the following form: *DISTNAME*[`-`*RELVER*[`-`*ARCH*[`-`*VENDOR*[`-`*VARIANT*]]]]

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osctl-image` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
