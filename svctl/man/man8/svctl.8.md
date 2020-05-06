# svctl 8                         2020-05-06                             20.03

## NAME
`svctl` - `runit` service and runlevel manager

## SYNOPSIS
`svctl` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`svctl` is a command-line tool that manages `runit` services and runlevels. It
is an abstraction on top of symlinks and `runsvchdir`. `runit` services are
stored in `/etc/runit/services`. Each runlevel is represented by a directory in
`/etc/runit/runsvdir` and contains links to services in `/etc/runit/services`.
`svctl` manages these symlinks.

`svctl` operates on the current system state. If you're using vpsAdminOS as
a live system, the changes will not be persistent. You need to make the changes
in your Nix configuration if you wish them to be permanent. `svctl` is useful
for temporary runlevel changes, such as on-demand runlevel switching and
enabling/disabling of services.

## COMMANDS
`list-services` `-a` | [*runlevel*]
  List either all services and their runlevels or services enabled
  in *runlevel*.

    `-a`, `--all`
      List services from all runlevels.

`enable` *service* [*runlevel*]
  Enable *service* in *runlevel*. *runlevel* defaults to `current`. This is
  an equivalent of
  `ln -s /etc/runit/services/<service> /etc/runit/runsvdir/<runlevel>/<service>`.

`disable` *service* [*runlevel*]
  Disable *service* from *runlevel*. *runlevel* defaults to `current`. This is
  an equivalent of `rm -f /etc/runit/runsvdir/<runlevel>/<service>`.

`list-runlevels`
  List available runlevels.

`runlevel`
  Print the current runlevel. `/etc/runit/runsvdir/current` points to the
  current runlevel.

`switch` *runlevel*
  Switch to *runlevel*. This is equivalent to `runsvchdir <runlevel>`. Services
  that are no longer enabled will be stopped and new services will be started.
  It may take several seconds for `runit` to notice the change.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`svctl` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
