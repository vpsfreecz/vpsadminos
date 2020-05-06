# osup 8                          2020-05-06                             20.03

## NAME
`osup` - system upgrade manager for vpsAdminOS

## SYNOPSIS
`osup` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osup` is a command line program managing system upgrades of vpsAdminOS. `osup`
handles upgrades and downgrades of `osctl`-managed data stored on ZFS pools.
This includes editing container/user/group configuration files, ZFS datasets
and other assets when some backward-incompatible change is introduced in
`osctld`.

`osup` is run by `osctld` when it import pools to ensure that the current
version of `osctld` is compatible with the data pools.

## GLOBAL OPTIONS
`--help`
  Show help message.

`-d`, `--debug`
  Print all executed commands.

`-n`, `--dry-run`
  Do not make any changes, print what would be done and exit.

`--version`
  Display the program version and exit.

## COMMANDS
`status` [*pool*]
  Print an overview of available and applied system migrations.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`check` [*pool*]
  Determine if *pool* or all pools marked as used by `osctld` are up to date,
  in need of an upgrade or a rollback. Each line of the output describes one ZFS
  pool. There are three columns: `pool`, `status` and `version`. `status`
  is one of `ok` - the pool is up-to-date, `outdated` - the pool needs
  an upgrade and `incompatible` - the pool needs a rollback. `version` is the
  pool's latest version that `osup` can work with.
  
  If `status` is `incompatible`, the pool needs to be rolled back to `version`.
  Your current OS version will not be able to do it. You need to upgrade the OS
  to a version that can work with the pool, even if your goal is to downgrade
  the OS. To use a pool on an older OS version, you need to roll it back on
  a newer OS to `version` using `osup rollback` *pool* *version*, then downgrade
  the OS.

`init` [`-f`] *pool*
  This command is run by `osctld` after it has installed *pool*. `osup` will
  set the pool's version by marking all supported migrations as applied.

    `-f`, `--force`
      Overwrite the version file even if it already exists and isn't empty.
      Unless you know what you're doing, this can potentially break both `osup`
      and `osctld` if the pool isn't in the expected state.

`upgrade` *pool* [*version*]
  Apply available system migrations to *pool*. `osup` will apply all available
  migrations until the system is up-to-date, or *version* has been reached.

`upgrade-all` [*version*]
  Run `upgrade` on all pools marked as used by `osctld`.

`rollback` *pool* [*version*]
  Rollback the latest applied system migration. If *version* is provided,
  the system will be rolled back to it.

`rollback-all` [*version*]
  Run `rollback` on all pools marked as used by `osctld`.

## FILES
`osup` is saving a list of applied migrations in a file on each pool. The file
is located at `<pool mountpoint>/.migrations`, or at
`<dataset mountpoint>/.migrations` in case `osctld` is scoped in a subdataset.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osup` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
