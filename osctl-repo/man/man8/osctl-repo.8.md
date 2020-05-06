# osctl-repo 8                    2020-05-06                             19.03.0

## NAME
`osctl-repo` - manage and interact with container images repositories

## SYNOPSIS
`osctl-repo` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osctl-repo` is a tool for accessing and managing container image repositories.
It works in two modes: `local` and `remote`.

In the `local` mode, `osctl-repo` manages container image repository in a chosen
directory. It can be used add, remove and configure images. `osctl-repo` does
not build the images, `osctl-image` can be used for that purpose.

The `remote` mode is used to interact with a remote repository over HTTP. In
this mode, `osctl-repo` can download remote images and keep them in a local
cache.

## GLOBAL OPTIONS
`-v`, `--version`
  Show program version and exit.

`-h`, `--help`
  Show help message and exit.

## COMMANDS
`local init`
  Initialize a new image repository in the current working directory.

`local ls`
  List images from a repository in the current working directory.

`local add` [*options*] *vendor* *variant* *arch* *distribution* *version*
  Add or replace image in the repository in the current working directory.

    `--archive` *file*
      Specify container image with root filesystem as a tarball.

    `--stream` *file*
      Specify container image with filesystems stored as ZFS streams.

    `--tag` *tag*
      Tag the image, e.g. `stable`, `latest` and `testing`. Can be used multiple
      times.

`local rm` *vendor* *variant* *arch* *distribution* *version*
  Remove image from the repository in the current working directory.

`local get path` *vendor* *variant* *arch* *distribution* *version* `tar`|`zfs`
  Get path to an image inside the repository.

`local default` *vendor*
  Set default vendor for the repository in the current working directory. Note
  that each repository has to have a default vendor.

`local default` *vendor* *variant*
  Set default *variant* for *vendor*.

`remote ls` [*options*] *url*
  List images from repository at *url*.

    `--cache` *dir*
      If set, the repository index is saved in this directory.

`remote fetch` [*options*] *url* *vendor* *variant* *arch* *distribution* *version*|*tag* `tar`|`zfs`
  Fetch an image from a remote repository at *url* and store it in the cache
  directory.

    `--cache` *dir*
      Use to store repository index and images. Required.

`remote get path` [*options*] *url* *vendor* *variant* *arch* *distribution* *version*|*tag* `tar`|`zfs`
  Fetch an image from a remote repository at *url* and print its path in the
  local cache directory.

    `--cache` *dir*
      Use to store repository index and images. Required.

    `--[no-]force-check`
      If enabled, `osctl-repo` fails if the remote repository is not accessible
      and the image is not available in the cache directory. Disabled by default.

`remote get stream`
  Fetch an image from a remote repository at *url* and write its contents
  to the standard output.

    `--cache` *dir*
      If set, the repository index and images are stored there.

    `--[no-]force-check`
      If enabled, `osctl-repo` fails if the remote repository is not accessible
      and the image is not available in the cache directory. Disabled by default.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osctl-repo` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
