# osctl 8                         2018-01-03                              0.1.0

## NAME
`osctl` - command line interface for `osctld`, the management daemon from
vpsAdminOS.

## SYNOPSIS
`osctl` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osctl` is a command line interface for `osctld`. `osctld` is a daemon from
vpsAdminOS that is used to manage unprivileged Linux containers, including
storage pools, user namespaces and CGroups for resource management.
`osctld` must be running before `osctl` can be used. `osctl` is available only
to root.

## POOLS
`osctld` fully utilizes ZFS and currently does not support any other file system.
`osctld` stores its data and configuration on provided zpools, no other path
in the system has to be persistent.

`osctld` needs at least one zpool to operate, see `pool install`
and `pool import`. When managing entities such as groups or containers
with multiple pools, you may need to specify pool name if there are name
conflicts, e.g. two groups or containers from different pools with the same
name. Two users with the same name are not allowed, because of system user/group
conflict. `osctld` by default selects the entity from the first pool that has
it. If you wish to manage such entities from other pools, you can use global
option `--pool` *name* or specify the group/container name/id as *pool*:*name*,
i.e. pool name and group/container name/id separated by colon.

## USER NAMESPACES
`osctld` makes it possible to run every container within a different user
namespace. It makes it possible by managing system users that are used to spawn
unprivileged containers. `osctld` manages all important system files, such as
**/etc/passwd**, **/etc/group**, **/etc/subuid**, **/etc/subgid** or
**/etc/lxc/lxc-usernet**. See the `user` commands.

## GROUPS
Groups represent the CGroup hierarchy. It is possible to define groups that
`osctld` will manage and configure their parameters. There are always at least
two groups: **root** and **default**. **root** group is the parent of all
managed groups and **default** is the group that containers are placed in unless
configured otherwise. Every container belongs to exactly one group.

See the `group` commands.

## CONTAINERS
`osctld` utilizes LXC to setup and run containers. Each container can belong
to a different user namespace and resource group. `osctld` set's up the
container's environment and LXC homes.

See the `ct` commands.

## GLOBAL OPTIONS
`--help`
  Show help message

`-p`, `--parsable`
  Show precise values, useful for parsing in scripts.

`-q`, `--quiet`
  Surpress output.

`--pool=arg`
  Pool name. Needed only when there is more than one pool installed and you wish
  to work with pools other than the first one, which is taken as the default
  one.

`--version`
  Display the program version and exit.

## COMMANDS
`pool install` [*options*] *name*
  Mark zpool *name* to be used with `osctld`.
  User property **org.vpsadminos.osctl:active** is set to **yes**. `osctld` will
  automatically import such marked pools on start. The pool is also immediatelly
  imported, see `pool import`.

    `--dataset` *dataset*
      Scope osctld to *dataset* on zpool *name*. All osctld's data will be stored
      in *dataset*. This option can be useful when the pool is used with other
      applications or data.

`pool uninstall` *name*
  Unmark zpool *name*, i.e. unset the user property set by `pool install`.
  No data is deleted from the pool, it will simply not be automatically imported
  when `osctld` starts.

`pool import` `-a`,`--all`|*name*
  Import zpool *name* into `osctld`. `osctld` will load all users, groups and
  containers from the pool.

    `-a`, `--all`
      Import all installed pools. This is what `osctld` does on start.

`pool export` *name*
  Export pool *name* from osctld. Currently, the containers are left running,
  system users are left registered. No data is deleted, the pool and all its
  content are merely removed from `osctld`.

`pool ls` [*names...*]
  List imported pools. If no *names* are provided, all pools are listed.
    
    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

`user new` *options* *name*
  Create a new user with user namespace configuration.

    `--pool` *name*
      Pool name.
    
    `--ugid` *ugid*
      User/group ID, required.

    `--offset` *offset*
      Offset of user/group IDs from zero used for UID/GID mapping, required.

    `--size` *size*
      Number of user/group IDs available within the user namespace, required.
      Should be 65536 or more.

`user del` *name*
  Delete user *name*.

`user ls` [*options*] [*names...*]
  List available users. If no *names* are provided, all users are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `--pool` *names*
      Filter by pool name, comma separated.

    `--registered`
      List only registered users.

    `--unregistered`
      List only unregistered users

`user show` [*options*] *name*
  Show user info.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`user reg` `all`|*name*
  Register all users or a selected user into the system, i.e. add records
  to **/etc/passwd** and **/etc/group**.

`user unreg` `all`|*name*
  Unregister all users or a selected user from the system, i.e. remove records
  from **/etc/passwd** and **/etc/group**.

`user subugids`
  Generate **/etc/subuid** and **/etc/subgid**.

`user assets` *name*
  List user's assets (datasets, files, directories) and their state.

`ct new` [*options*] *id*
  Create a new container. Selected user and group have to be from the same pool
  the container is being created on.
  
    `--pool` *name*
      Pool name. Defaults to the first available pool.

    `--user` *name*
      User name, required.

    `--group` *name*
      Group name, defaults to group *default* from selected *pool*.

    `--template` *file*
      Template file, required. The *file* must be a **tar.gz** archive, with
      name in the following format: <*distribution*>-<*version*>\*.tar.gz.

`ct del` *id*
  Stop and delete container *id*.

`ct ls` [*options*] [*ids...*]
  List containers. If no *ids* are provided, all containers matching filters
  are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

    `--pool` *names*
      Filter by pool, comma separated.

    `-u`, `--user` *users*
      Filter by user name, comma separated.

    `-g`, `--group` *groups*
      Filter by group name, comma separated.

    `-s`, `--state` *states*
      Filter by state, comma separated. Available states:
      **stopped**, **starting**, **running**, **stopping**, **aborting**, **freezing**,
      **frozen**, **thawed**.

    `-d`, `--distribution` *distributions*
      Filter by distribution, comma separated.

    `-v`, `--version` *versions*
      Filter by distribution version, comma separated.

`ct show` [*options*] *id*
  Show all or selected parameters of container *id*.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct start` [*options*] *id*
  Start container *id*.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

`ct stop` [*options*] *id*
  Stop container *id*.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

`ct restart` [*options*] *id*
  Restart container *id*.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

`ct attach` *id*, `ct enter` *id*
  Attach container *id* and open a shell.

`ct console` [*options*] *id*
  Attach container console. Unlike in LXC, this console is persistent across
  container reboots. It can be attached even when the container is stopped.
  The console can be detached using **Ctrl-a q**.

  `-t`, `--tty` *n* - Select which TTY to attach, defaults to **0**.

`ct exec` *id* *cmd...*
  Attach container *id* and execute command *cmd* within a shell.
  stdin/stdout/stderr of *cmd* is piped to your current shell.

`ct set hostname` *id* *hostname*
  Set container hostname. Depending on distribution, the hostname is configured
  within the container and an entry is added to `/etc/hosts`. The hostname
  is configured on every container start.

`ct set dns-resolver` *id* *address...*
  Configure DNS resolvers for container *id*. At least one DNS resolver is
  needed. Given DNS resolvers are written to the container's `/etc/resolv.conf`
  on every start.

  Note that when you assign a bridged veth with DHCP to the container, it will
  override `/etc/resolv.conf` with DNS servers from DHCP server.

`ct set nesting` *id* `enabled`|`disabled`
  Allow/disallow LXC nesting for container *id*. The container needs to be
  restarted for the change to take effect.

`ct unset hostname` *id*
  Unset container hostname. `osctld` will not touch the container's hostname
  anymore.

`ct unset dns-resolver` *id*
  Unset container DNS resolvers. `osctld` will no longer manipulate the
  container's `/etc/resolv.conf`.

`ct chown` *id* *user*
  Move container *id* to user namespace *user*. The container has to be stopped
  first.

`ct chgrp` *id* *group*
  Move container *id* to group *group*. The container has to be stopped first.

`ct passwd` *id* *user* [*password*]
  Change password of *user* in container *id*. The user has to already exist.
  If *password* is not given as an argument, it is prompted for on stdin.
  The container has to be running for this command to work, as it is using
  `passwd` or `chpasswd` from the container's system.

`ct su` *id*
  Switch to the user of container *id* and cd to its LXC home. The shell
  is tailored only for container *id*, do not use it to manipulate any other
  containers, even in the same LXC home. Every container can have a different
  CGroup configuration, which would be broken.

  Also not that when a container is started from this shell using `lxc-start`,
  `ct console` for tty0 will not be functional.

`ct cd` [*options*] *id*
  Opens a new shell with changed current working directory, based on *options*.
  When no option is specified, the directory is changed to the container's
  rootfs. Close the shell to return to your previous session.
  
    `-l`, `--lxc`
      Go to LXC config directory
    
    `-r`, `--runtime`
      Go to */proc/<init_pid>/root*. The container must be running for the path
      to exist.

`ct log cat` *id*
  Write the contents of container *id* log to the stdout.

`ct log path` *id*
  Write the path to the log file of container *id* to stdout.

`ct monitor` *id*
  Monitor state changes of container *id* and print them on standard output.
  If global option `-p`, `--parsable` is used, the state changes are reported
  in JSON.

`ct wait` *id* *state...*
  Block until container *id* enters one of given states.

`ct assets` *id*
  List container assets and their state.

`ct cgparams ls` [*options*] *id* [*parameters...*]
  List CGroup parameters for container *id*. If no *parameters* are provided,
  all configured parameters are listed.

    `-H`, `--hide-header`
        Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters adn exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

    `-S`, `--subsystem` *subsystem*
      Filter by CGroup subsystem, comma separated.

    `-a`, `--all`
      Include parameters from parent groups up to root group.

`ct cgparams set` *id* *parameter* *value...*
  Set CGroup parameter *parameter* of container *id* to *value*. `osctld` will
  make sure this parameter is always set when the container is started. The
  parameter can be for example `cpu.shares` or `memory.limit_in_bytes`. CGroup
  subsystem is derived from the parameter name, you do not need to supply it.

  It is possible to set multiple values for a parameter. The values are written
  to the parameter file one by one. This can be used for example for the
  `devices` CGroup subsystem, where you may need to write to `devices.deny` and
  `devices.allow` multiple times.

`ct cgparams unset` *id* *parameter*
  Unset CGroup parameter *parameter* from container *id*. Value of the parameter
  is not changed, the parameter is merely removed from `osctld` config.

`ct cgparams apply` *id*
  Apply all CGroup parameters defined for container *id*, its group and all
  its parent groups, all the way up to the root group.

`ct prlimits ls` *id* [*limits...*]
  List configured resource limits. If no *limits* are provided, all configured
  limits are listed.

    `-H`, `--hide-header`
        Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters adn exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct prlimits set` *id* *limit* *soft\_and\_hard*, `ct prlimits set` *id* *limit* *soft* *hard*
  Set resource *limit* on container *id*. Limit names and their descriptions
  can be found in setrlimit(2). The permitted names are the "RLIMIT\_" resource
  names in lowercase without the "RLIMIT\_" prefix, eg. `RLIMIT_NOFILE` should
  be specified as **nofile**.

  If *hard* is not provided, it equals to the *soft* limit. The value can be
  either an integer or **unlimited**.

`ct prlimits unset` *id* *limit*
  Unset resource *limit* from container *id*.

`ct netif ls` [*options*] *id*
  List configured network interfaces for container *id*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-l`, `--link` *bridge*
      Filter by linked bridge.

    `-t`, `--type` *type*
      Filter by interface type (`bridge` or `routed`)

`ct netif new bridge` [*options*] `--link` *bridge* *id* *name*
  Create a new bridge network interface in container *id*. This will create
  a pair of veth interfaces, one on the host, one in the container. The veth
  on the host will be linked to *bridge*. The interface will appear as *name*
  within the container. *bridge* is not managed by `osctld`, it must be provided
  by the system administrator in advance.

  Currently, the container uses DHCP to configure the interface.
  The container has to be stopped for this command to be allowed.

    `--link` *bridge*
      What bridge should the interface be linked with, required.

    `--hwaddr` *addr*
      Set a custom MAC address. Every **x** in the address is replaced by
      a random value. By default, the address is dynamically allocated.

`ct netif new routed` [*options*] `--via` *network* *id* *name*
  Create a new routed network interface in container *id*. Like for **bridge**
  interface, a pair veth is created. The difference is that the veth is not part
  of any bridge. Instead, IP addresses are routed to the container via
  an interconnecting *network*. `osctld` will automatically setup appropriate
  routes on the host veth interface. The interface will appear as *name* within
  the container.
  
  The container has to be stopped for this command to be allowed.

    `--via` *network*
      Route via network, required. Can be used once for IPv4 and once for IPv6,
      depending what addresses you want to be able to route.

    `--hwaddr` *addr*
      Set a custom MAC address. Every **x** in the address is replaced by
      a random value. By default, the address is dynamically allocated.

`ct netif del` *id* *name*
  Remove interface *name* from container *id*.
  The container has to be stopped for this command to be allowed.

`ct netif ip add` *id* *name* *addr*
  Add IP address *addr* to interface *name* of container *id*. `osctld` will
  setup routing in case of **routed** interface and add the IP address to the
  container's interface.

`ct netif ip del` *id* *name* *addr*
  Remove IP address *addr* from interface *name* of container *id*.

`ct netif ip ls` *id* *name*
  List IP addresses assigned to interface *name* of container *id*.

`ct mounts ls` *id*
  List mounts of container *id*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct mounts new` *options* *id*
  Create a new mount for container *id* described by *options*. The *fs* is not
  mounted immediately, but the next time the container starts.

    `--fs` *fs*
      File system or device to mount, required.

    `--mountpoint` *mountpount*
      Mountpoint within the container, required. The path has to be relative to
      the container's root, i.e. no leading slash.

    `--type` *type*
      File system type, required.

    `--opts` *opts*
      Options, required. Standard mount options depending on the filesystem
      type, with two extra options from LXC: `create=file` and `create=dir`.

`ct mounts del` *id* *mountpoint*
  Remove *mountpoint* from container *id*. The *mountpoint* is not unmounted
  immediatelly, but when the container stops.

`group new` *options* *name*
  Create a new group for resource management.

    `--pool` *name*
      Pool name, optional.

    `-p`, `--path` *path*
      CGroup path in all subsystems, required. The path is relative to the root
      group.

    `--cgparam` *parameter*=*value*
      Set CGroup parameter, may be used more than once. See `group cgparams set`
      for what the parameter is.

`group del` *name*
  Delete group *name*. The group musn't be used by any container.

`group ls` [*options*] [*names...*]
  List available groups. If no *names* are provided, all groups are listed.
    
    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

    `--pool` *names*
      Filter by pool, comma separated.

`group show` *name*
  Show group info.

`group cgparams ls` [*options*] *name* [*parameters...*]
  List CGroup parameters for group *name*. If no *parameters* are provided,
  all configured parameters are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters adn exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

    `-S`, `--subsystem` *subsystem*
      Filter by CGroup subsystem, comma separated.

    `-a`, `--all`
      Include parameters from parent groups up to root group.

`group cgparams set` *name* *parameter* *value...*
  Set CGroup parameter *parameter* of group *name* to *value*. `osctld` will
  make sure this parameter is always set when the container is started. The
  parameter can be for example `cpu.shares` or `memory.limit_in_bytes`. CGroup
  subsystem is derived from the parameter name, you do not need to supply it.

  It is possible to set multiple values for a parameter. The values are written
  to the parameter file one by one. This can be used for example for the
  `devices` CGroup subsystem, where you may need to write to `devices.deny` and
  `devices.allow` multiple times.

`group cgparams unset` *name* *parameter*
  Unset CGroup parameter *parameter* from group *name*. Value of the parameter
  is not changed, the parameter is merely removed from `osctld` config.

`group cgparams apply` *name*
  Apply all CGroup parameters defined for group *name* and all its parent
  groups, all the way up to the root group.

`group assets` *name*
  List group's assets (datasets, files, directories) and their state.

`monitor`
  Print all events reported by `osctld` to standard output. If global option
  `-p`, `--parsable` is used, the events are printed in JSON.

`history` [*pool...*]
  Print management history of all or selected pools. If global option
  `-p`, `--parsable` is used, the events are printed in JSON.

`help` [*command...*]
  Shows a list of commands or help for one command

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osctl` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
