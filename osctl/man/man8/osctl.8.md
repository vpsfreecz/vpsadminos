# osctl 8                         2020-10-12                             20.03

## NAME
`osctl` - command line interface for `osctld`, the management daemon from
vpsAdminOS.

## SYNOPSIS
`osctl` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osctl` is a command line interface for `osctld`. `osctld` is a daemon from
vpsAdminOS that is used to manage unprivileged Linux containers, including
storage pools, user namespaces and cgroups for resource management.
`osctld` must be running before `osctl` can be used. `osctl` is available only
to root.

## POOLS
`osctld` uses ZFS for persistent storage and it is the only supported file
system. ZFS pools are created and imported by the administrator or the OS,
then they have to be installed into `osctld`, see commands `pool install`
and `pool import`. One `osctl pool` corresponds to one ZFS pool, `osctld`
requires at least one pool to operate.

Pools are independent entities carrying their own configuration and data, such
as users, groups, containers, images, log files and other configuration
files. Pools can be imported and exported at runtime, taking all associated
entities with them.

When managing entities such as groups or containers with multiple pools, you may
need to specify pool name if there are name conflicts, e.g. two groups or
containers from different pools with the same name. Two users with the same name
are not allowed, because of system user/group conflict. `osctld` by default
selects the entity from the first pool that has it. If you wish to manage such
entities from other pools, you can use global option `--pool` *pool* or specify
the group/container name/id as *pool*:*ctid|user|group*, i.e. pool name
and group/container name/id separated by colon.

## ID RANGES
ID ranges are used to track user/group ID allocations into user namespace maps.
There is one default ID range on each pool, with the possibility of creating
custom ID ranges. User namespace maps allocated from one ID range are guaranteed
to be unique, i.e. no two containers can share the same user/group IDs, making
them isolated.

See the `id-range` command family.

## USER NAMESPACES
`osctld` makes it possible to run every container with a different user
namespace mapping to increate isolation. For each mapping, `osctld` manages
an unprivileged system user and takes care of all important system files, such
as **/etc/passwd**, **/etc/group**, **/etc/subuid**, **/etc/subgid** or
**/etc/lxc/lxc-usernet**.

See the `user` command family.

## GROUPS
Groups represent the cgroup hierarchy and are used for system resource
accounting and control. Each pool has two groups by default: `/` and `/default`.
`/` is the parent of all managed groups and `/default` is the group that new
containers are placed in, unless configured otherwise. Every container belongs
to exactly one group.

See the `group` command family.

## CONTAINERS
Every container uses user namespace mapping, resource control groups
and resides in its own ZFS dataset. Containers are usually created from
images, see `IMAGES`.

Under the hood, `osctld` utilizes LXC to setup and run containers.

### IMAGES
An image is a tar archive generated e.g. by `ct export` or built using the
`osctl-image` utility. It contains container configuration and filesystems.

Containers can be created from local images using `ct import`. Images can also
be automatically downloaded from remote repositories over HTTP using `ct new`.
vpsAdminOS comes with one such repository preconfigured, it can be browsed
at <https://images.vpsadminos.org> or using command
`repository images ls default`.

See the `repository` command family, `ct export`, `ct import` and `ct new`.

### MANIPULATION
Commands for container manipulation:

 - `ct new` - create a new container
 - `ct reinstall` - remove root file system content and import image
 - `ct cp` - copy container to another to the same or a different pool
 - `ct mv` - move container to a different pool or change its id
 - `ct chown` - change container user
 - `ct chgrp` - change container group
 - `ct set`, `ct unset` - configure container properties

### INTERACTION
 - `ct start`, `ct stop`, `ct restart` - control containers
 - `ct attach` - enter a container and open an interactive shell
 - `ct console` - attach a container's console
 - `ct exec` - execute an arbitrary command within a container
 - `ct runscript` - execute a script from the host within a container
 - `ct passwd` - set password for a user within a container

### AUTO-STARTING
By default, created containers have to be started manually. It is possible to
mark containers that should be automatically started when their pool is imported
using command `ct set autostart`.

When a pool is imported, its containers marked for start are sorted in a queue
based on their priority. Containers are then started in order, usually several
containers at once in parallel. The start queue can be accessed using command
`pool autostart queue`, cancelled by `pool autostart cancel` and manually
triggered using `pool autostart trigger`.

The number of containers started at once in parallel can be set by
`pool set parallel-start`. There is also `pool set parallel-stop` which
controls how many containers at once are being stopped when the pool is being
exported from `osctld`.

### CONTAINER NETWORKING
`osctld` supports the veth device in two configurations: bridged and routed.

Bridge interfaces are simpler to configure, but do not provide a great isolation
of the network layer. The interfaces can be configured either statically or
using DHCP. See command `ct netif new bridge` for more information.

Routed interfaces rely on other routing protocols such as OSFP or BGP. `osctld`
adds configured routes to the container's network interfaces and it is up to
the routing protocol to propagate them wherever needed. Routed interfaces
are harder to configure, but provide a proper isolation of the network layer.
See command `ct netif new routed` for more information.

### DISTRIBUTION CONFIGURATION
`osctld` is generating config files inside the container, which are then read
and evaluated by its init system on boot. This is used primarily for hostname
and network configuration. Supported distributions are:

 - Alpine
 - Arch
 - CentOS
 - Debian
 - Devuan
 - Fedora
 - Gentoo
 - NixOS
 - openSUSE
 - Slackware
 - Ubuntu
 - Void

Other distributions have to be configured manually from the inside.

### CGROUP LIMITS
cgroup limits can be set either on groups, where they apply to all containers
in a group and also to all child groups, or directly on containers. cgroup
parameters can be managed by commands  `group cgparams` and `ct cgparams`.
To make frequently used limits simpler to configure, there are several commands
built on top of `group|ct cgparams`:

 - `group|ct set memory` to configure memory and swap limits
 - `group|ct set cpu-limit` to limit CPU usage using CPU quotas

### DEVICES
Access to devices is managed using the `devices` cgroup controller. Groups
and containers can be given permission to read, write or mknod configured
block and character devices. If a container wants to access a device, access
to the device has to be allowed in its group and all its parent groups up to the
root group. This is why managing devices using `group|ct cgparams` commands
would be impractical and special commands `group|ct devices` exist.

The root group by default allows access to fundamental devices such as
`/dev/null`, `/dev/urandom`, TTYs, etc. These devices are marked as inheritable
and all child groups automatically inherit them and pass them to their
containers. Additional devices can be added in two ways:

 - add the devices too the root group and let all other groups inherit them,
   this will let all containers to access the new devices
 - add the devices just to the selected group or container, but all parent
   groups must still provide it, except no other group or container will
   automatically inherit it

See the `group|ct devices` command family.

### DATASETS
Every container resides in its own ZFS dataset. It is also possible to create
additional subdatasets and mount them within the container. See the
`ct dataset` command family for more information.

### MOUNTS
Arbitrary directories from the host can be mounted inside containers. Mounted
directories should use the same user namespace mapping as the container,
otherwise their contents will appear be owned by `nobody:nogroup` and access
permission will not work as they should.

See the `ct mounts` family of commands.

### EXPORT/IMPORT
Existing containers can be exported to a tar archive and later imported
to the same or a different vpsAdminOS instance. The tar archive contains
the container's root file system including all subdatasets and osctl
configuration.

See commands `ct export` and `ct import` for more information.

### SEND/RECEIVE
`osctld` has support for transfering containers between different vpsAdminOS
instances with SSH used as a transport channel. Each vpsAdminOS node has
a system user called `osctl-ct-receive`. The source node is connecting to the
`osctl-ct-receive` user on the destination node. Authentication is based
on public/private keys.

On the source node, a public/private key pair is needed. It can be generated by
`send key gen`, or the keys can be manually installed to paths given by
`send key path public` and `send key path private`. Through another
communication channel, picked at your discretion, the public key of the source
node must be transfered to the destination node and authorized to send
containers to that node. Once transfered, the key can be authorized using
`receive authorized-keys add` or `receive authorized-keys set`.

The container transfer consists of several steps:

 - `ct send config` is used to prepare environment on the destination node
   and copy configuration
 - `ct send rootfs` sends over the container's rootfs
 - `ct send sync` optionally syncs rootfs changes, can be called multiple times
 - `ct send state` stops the container on the source node, performs
   another rootfs sync and finally starts the container on the destination node
 - `ct send cleanup` is used to remove the container from the source node

Up until `ct send state`, the send can be cancelled using
`ct send cancel`.

`ct send` will perform all necessary send steps in succession.

### ADMINISTRATION
Useful commands:

 - `ct top` - interactive container monitor
 - `ct ps` - list container processes
 - `ct pid` - identify containers by PID
 - `ct log cat`, `ct log path` - view container log file
 - `ct su` - switch to the container user
 - `ct cd` - switch to the container root file system directory

### TROUBLESHOOTING
 - Check `ct log cat`
 - Check `ct assets`
 - Check `healthcheck -a`
 - Command `ct reconfigure` can be used to regenerate LXC configuration
 - Command `ct recover kill` can be used to kill unresponsive container processes
 - Command `ct recover cleanup` can be used to cleanup after a container crashed
 - Command `ct recover state` can be used to re-check container status

## ASSETS AND HEALTH CHECKS
To keep track of all the datasets, directories and files `osctld` is managing,
each entity has command `assets`. It prints a list of all managed resources,
their purpose and state. Command `healthcheck` then checks the state
of all assets of selected pools and reports errors.

## USER ATTRIBUTES
All entities support custom user attributes that can be used to store
additional data, i.e. a simple key-value store. Attribute names and values
are stored as a string. The intended attribute naming is *vendor*:*key*, where
*vendor* is a reversed domain name and *key* an arbitrary string, e.g.
`org.vpsadminos.osctl:declarative`.

Attributes can be set with command `set attr`, unset with `unset attr` and
read by `ls` or `show` commands.

## GLOBAL OPTIONS
`--help`
  Show help message

`-j`, `--json`
  Format output in JSON.

`-p`, `--parsable`
  Show precise values, useful for parsing in scripts.

`--[no-]color`
  Toggle colorized output for commands that support it. Enabled by default.

`-q`, `--quiet`
  Surpress output.

`--pool` *pool*
  Pool name. Needed only when there is more than one pool installed and you wish
  to work with pools other than the first one, which is taken as the default
  one.

`--version`
  Display the program version and exit.

## COMMANDS
`pool install` [*options*] *pool*
  Mark zpool *pool* to be used with `osctld`.
  User property **org.vpsadminos.osctl:active** is set to **yes**. `osctld` will
  automatically import such marked pools on start. The pool is also immediately
  imported, see `pool import`.

    `--dataset` *dataset*
      Scope osctld to *dataset* on zpool *pool*. All osctld's data will be stored
      in *dataset*. This option can be useful when the pool is used with other
      applications or data.

`pool uninstall` *pool*
  Unmark zpool *pool*, i.e. unset the user property set by `pool install`.
  No data is deleted from the pool, it will simply not be automatically imported
  when `osctld` starts.

`pool import` `-a`,`--all`|*pool*
  Import zpool *pool* into `osctld`. `osctld` will load all users, groups and
  containers from the pool.

    `-a`, `--all`
      Import all installed pools. This is what `osctld` does on start.

    `-s`, `--[no-]autostart`
      Start containers that are configured to be started automatically. Enabled
      by default.

`pool export` [*options*] *pool*
  Export pool *pool* from `osctld`. No data is deleted, the pool and all its
  content is merely removed from `osctld`. `pool export` aborts if any container
  from the exported pool is running, unless option `-f`, `--force` is given.

    `-f`, `--force`
      Export the pool even if there are containers running or an autostart plan
      is still in progress. Running containers are stopped if `-s`,
      `--stop-containers` is set, otherwise they're left alone.

    `-s`, `--[no-]stop-containers`
      Stop all containers from pool *pool*. Enabled by default.

    `-u`, `--[no-]unregister-users`
      Unregister users from pool *pool* from the system, i.e. remove entries
      from `/etc/passwd` and `/etc/group`. Enabled by default.

`pool ls` [*names...*]
  List imported pools. If no *names* are provided, all pools are listed.
    
    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`pool show` *pool*
  Show information about imported pool *pool*.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`pool assets` [*options*] *pool*
  List pool assets and their state.

    `-v`, `--verbose`
      Show detected errors.

`pool autostart queue` [*options*] *pool*
  Print containers waiting in the auto-start queue. The containers are ordered
  by start priority and id.
    
    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

`pool autostart trigger` *pool*
  Start all containers from pool *pool* that are configured to be started
  automatically. This can be used to ensure that all containers that are
  supposed to be running are actually running.

`pool autostart cancel` *pool*
  Cancel starting of containers that are configured to be started automatically
  and are left in the start queue.

`pool set parallel-start` *pool* *n*
  Configure how many containers should be started simultaneously by auto-start
  on pool import. Defaults to *2*.

  The default value is suitable for HDD-based zpools. For SSD zpools, you might
  want to increase the value together with `parallel-stop`, as the storage won't
  be a bottleneck.

`pool unset parallel-start` *pool*
  Reset `parallel-start` to the default value.

`pool set parallel-stop` *pool* *n*
  Configure how many containers should be stopped simultaneously on pool export,
  usually via `osctl shutdown`. Defaults to *4*.

`pool unset parallel-stop` *pool*
  Reset `parallel-stop` to the default value.

`pool set attr` *pool* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for pool *pool*. Configured
  attributes can be read with `pool ls` or `pool show` using the `-o`, `--output`
  option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

`pool unset attr` *pool* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of pool *pool*.

`id-range new` *options* *id-range*
  Create a new ID range.

    `--start-id` *start-id*
      The first user/group ID. Required.

    `--block-size` *block-size*
      Number of user/group IDs that make up the minimum allocation unit.
      Should be set to `65536` or more.

    `--block-count` *count*
      How many blocks from *start-id* should the range include. Defines the
      maximum number of user namespace maps that can be allocated from this
      range. Required.

`id-range del` *id-range*
  Delete ID range *id-range*. Only ranges with empty allocation table can be
  deleted.

`id-range ls` [*id-ranges...*]
  List configured ID ranges.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`id-range show` *id-range*
  Show information about a specific ID range.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`id-range table ls` [*options*] *id-range* [`all`|`allocated`|`free`]
  Print the allocation table.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`id-range table show` [*options*] *id-range* *block-index*
  Print information about block allocation.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

`id-range allocate` *id-range*
  Allocate one or more blocks from ID range *id-range*.

    `--block-count` *n*
      How many blocks to allocate. Defaults to 1 block.

    `--block-index` *n*
      Optional index of the first allocated block in the allocation table.

    `--owner` *string*
      Optional owner of the allocated blocks.

`id-range free` *id-range*
  Free block allocation from ID range *id-range*.

    `--block-index` *n*
      Index of the first allocated block to free.

    `--owner` *owner*
      Free allocations belonging to *owner*.

`id-range assets` [*options*] *id-range*
  List ID range assets and their state.

    `-v`, `--verbose`
      Show detected errors.

`id-range set attr` *id-range* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for ID range *id-range*. Configured
  attributes can be read with `id-range ls` or `id-range show` using the `-o`,
  `--output` option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

`id-range unset attr` *id-range* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of ID range *id-range*.

`user new` *options* *user*
  Create a new user with user namespace mapping configuration.

  If option `--id-range` is used, or no mapping is set using options
  `--map`, `--map-uid` and `--map-gid`, a new UID/GID range is allocated from
  *id-range* and a default mapping is created.

  To use ID range block allocation with a custom mapping, allocate the block
  first using command `id-range allocate` and then use option
  `--id-range-block-index` together with `--map`, `--map-uid` or `--map-gid`.

    `--pool` *pool*
      Pool name.

    `--id-range` *id-range*
      Name of an ID range to allocate UID/GID from. Defaults to ID range
      called `default`.

    `--id-range-block-index` *n*
      Use an existing UID/GID allocation from *id-range*, or allocate a new
      block at index *n*. The owner of the allocated block is not changed, so
      existing blocks will not get automatically freed when the user is deleted.

    `--map` *id*:*lowerid*:*count*
      Provide both UID and GID mapping for user namespace. *id* is the beginning
      of the range inside the user namespace, *lowerid* is the range beginning
      on the host and *count* is the number of mapped IDs both inside and
      outside the user namespace. This option can be used mutiple times.

    `--map-uid` *uid*:*loweruid*:*count*
      Provide UID mapping for user namespace. *uid* is the beginning of
      the range inside the user namespace, *loweruid* is the range beginning
      on the host and *count* is the number of mapped UIDs both inside and
      outside the user namespace. This option can be used mutiple times.

    `--map-gid` *gid*:*lowergid*:*count*
      Provide GID mapping for user namespace. *gid* is the beginning of
      the range inside the user namespace, *lowergid* is the range beginning
      on the host and *count* is the number of mapped GIDs both inside and
      outside the user namespace. This option can be used mutiple times.

    `--[no-]standalone`
      Make the user standalone. Standalone users are not deleted together with
      their containers, but are left behind. Enabled by default.

`user del` *user*
  Delete user *user*.

`user ls` [*options*] [*names...*]
  List available users. If no *names* are provided, all users are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `--pool` *names*
      Filter by pool name, comma separated.

    `--registered`
      List only registered users.

    `--unregistered`
      List only unregistered users

`user show` [*options*] *user*
  Show user info.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`user reg` `all`|*user*
  Register all users or a selected user into the system, i.e. add records
  to **/etc/passwd** and **/etc/group**.

`user unreg` `all`|*user*
  Unregister all users or a selected user from the system, i.e. remove records
  from **/etc/passwd** and **/etc/group**.

`user subugids`
  Generate **/etc/subuid** and **/etc/subgid**.

`user assets` [*options*] *user*
  List user's assets (datasets, files, directories) and their state.

    `-v`, `--verbose`
      Show detected errors.

`user map` *user* [`uid` | `gid` | `both`]
  List configured UID/GID mappings.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

`user set standalone` *user*
  Mark the user as standalone. Standalone users are not automatically deleted
  with their containers.

`user unset standalone` *user*
  Remove the standalone mark. The user will be automatically deleted when the
  last container that uses it is deleted.

`user set attr` *user* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for user *user*. Configured
  attributes can be read with `user ls` or `user show` using the `-o`, `--output`
  option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

`user unset attr` *user* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of user *user*.

`ct new` [*options*] *ctid*
  Create a new container. Selected user and group have to be from the same pool
  the container is being created on.

  Containers are usually created from images. Images are downloaded from remote
  repositories. The desired image can be specified by `--distribution`
  and optionally also `--version`, `--arch`, `--vendor` or `--variant`.
  All configured repositories are searched by default.

  Use `ct import` to create containers from local files.

  Containers can be created in custom datasets, located anywhere on the pool.
  The dataset can be selected using option `--dataset`. If the dataset already
  containers rootfs and you do not wish to use any image, signal this with
  option `--skip-image`. Otherwise, the image to be used can be selected
  using any of the methods above.
  
    `--pool` *pool*
      Pool name. Defaults to the first available pool.

    `--user` *user*
      User name. If not provided, a new user is created.

    `--group` *group*
      Group name, defaults to group *default* from selected *pool*.

    `--dataset` *dataset*
      Use a custom dataset for the container's rootfs. The dataset and all its
      parents are created, if it doesn't already exist. If used with
      `--skip-image`, the dataset is expected to already contain the rootfs
      and `--distribution` and `--version` have to be provided.

    `--skip-image`
      Do not import any image, leave the container's root filesystem empty.
      Useful for when you wish to setup the container manually.

    `--distribution` *distribution*
      Distribution name in lower case, e.g. alpine, centos, debian, ubuntu.

    `--version` *version*
      Distribution version. The format can differ among distributions, e.g.
      alpine `3.6`, centos `7.0`, debian `9.0` or ubuntu `16.04`.

    `--arch` *arch*
      Container architecture, e.g. `x86_64` or `x86`. Defaults to the host system
      architecture.

    `--vendor` *vendor*
      Vendor to be selected from the remote image repository.

    `--variant` *variant*
      Vendor variant to be selected from the remote image repository.

    `--repository` *repository*
      Instead of searching all configured repositories from appropriate pool,
      use only repository *name*. The selected repository can be disabled.

`ct del` *ctid*
  Stop and delete container *ctid*.

    `-f`, `--force`
      Delete the container even if it is running. By default, running containers
      cannot be deleted.

`ct reinstall` [*options*] *ctid*
  Reinstall container from image. The container's rootfs is deleted
  and an image is imported again. The container's subdatasets remain unaffected.
  Container configuration can change dependending on what is in the image
  configuration file -- configuration values from the image replace the current
  configuration.

  If no image info is given via command-line options, `osctld` will attempt
  to find the appropriate image for the container's distribution version in
  remote repositories. This may not work if the container was created
  from a local file, stream or if the distribution is too old and no longer
  supported.

  As the imported image can be a ZFS stream, it is necessary to delete all
  snapshots of the container's root dataset. By default, `ct reinstall` will
  abort if there are snapshots present. You can use option `-r`,
  `--remove-snapshots` to remove them.

    `--from-file` *file*
      Create the container from a container image.

    `--distribution` *distribution*
      Distribution name in lower case, e.g. alpine, centos, debian, ubuntu.

    `--version` *version*
      Distribution version. The format can differ among distributions, e.g.
      alpine `3.6`, centos `7.0`, debian `9.0` or ubuntu `16.04`.

    `--arch` *arch*
      Container architecture, e.g. `x86_64` or `x86`. Defaults to the host system
      architecture.

    `--vendor` *vendor*
      Vendor to be selected from the remote image repository.

    `--variant` *variant*
      Vendor variant to be selected from the remote image repository.

    `--repository` *repository*
      Instead of searching all configured repositories from appropriate pool,
      use only repository *name*. The selected repository can be disabled.

    `-r`, `--remove-snapshots`
      Remove all snapshots of the container's root dataset. `ct reinstall`
      cannot proceed if there are snapshots present.

`ct ls` [*options*] [*ctids...*]
  List containers. If no *ids* are provided, all containers matching filters
  are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `--pool` *pools*
      Filter by pool, comma separated.

    `-u`, `--user` *users*
      Filter by user name, comma separated.

    `-g`, `--group` *groups*
      Filter by group name, comma separated.

    `-S`, `--state` *states*
      Filter by state, comma separated. Available states:
      **stopped**, **starting**, **running**, **stopping**, **aborting**, **freezing**,
      **frozen**, **thawed**.

    `-e`, `--ephemeral`
      Filter ephemeral containers.

    `-p`, `--persistent`
      Filter persistent (non-ephemeral) containers.

    `-d`, `--distribution` *distributions*
      Filter by distribution, comma separated.

    `-v`, `--version` *versions*
      Filter by distribution version, comma separated.

`ct tree` *pool*
  Print the group and container hierarchy from *pool* in a tree.

`ct show` [*options*] *ctid*
  Show all or selected parameters of container *ctid*.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`ct mount` *ctid*
  Mount all container's datasets if they are not already mounted.

`ct start` [*options*] *ctid*
  Start container *ctid*.

    `-w`, `--wait` *seconds*
      How many seconds to wait for the container to enter state `running`.
      Defaults to `60` seconds. Set to `0` to return immediately.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

    `-q`, `--queue`
      Enqueue the start operation using the pools autostart facility. The pool
      is configured to start a certain number of containers in parallel. Use
      this option, to add the container to the queue. This is useful when you're
      manually starting a large number of containers.

    `-p`, `--priority` *n*
      Priority for the autostart queue. This option can be used together with
      `-q`, `--queue`. See `ct set autostart` for more information.

    `-D`, `--[no-]debug`
      Configure LXC to write debug messages to the container's log file, see
      `ct log` commands.

`ct stop` [*options*] *ctid*
  Stop container *ctid*. By default, `osctld` will send a signal to the container's
  init process to cleanly shutdown and wait until it finishes or *timeout*
  seconds passes. If it time outs, the container is killed. This behaviour can
  be changed with options `--timeout`, `--kill` and `--dont-kill`.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

    `-k`, `--kill`
      Do not request a clean shutdown, kill the container immediately.

    `--dont-kill`
      If the clean shutdown does not finish in *timeout* seconds, exit with
      error, do not kill the container.

    `-t`, `--timeout` *timeout*
      How many seconds to wait for the container to cleanly shutdown before
      killing it or failing, depending on whether option `--dont-kill` is set.
      The default timeout is *60* seconds.

`ct restart` [*options*] *ctid*
  Restart container *ctid*. By default, `ct restart` calls `ct stop` and `ct start`
  in succession. Like with `ct stop`, if the container does not cleanly shutdown
  in *timeout* seconds, it is killed. This behaviour can be changed with options
  `--timeout`, `--kill` and `--dont-kill`.

  If option `--reboot` is used, the container's init process is signaled to
  reboot the system. `osctld` has no way of knowing whether the init process
  responds and the reboot actually takes place.

    `-w`, `--wait` *seconds*
      How many seconds to wait for the container to enter state `running`.
      Applicable only for full restarts, i.e. when `--reboot` is not set.
      Defaults to `60` seconds. Set to `0` to return immediately.

    `-F`, `--[no-]foreground`
      Open container console (can be later detached), see `ct console`.

    `-r`, `--reboot`
      Request a reboot of the container by signaling its init process. 
      If the init process does not respond to the configured signal, nothing
      happens.

    `-k`, `--kill`
      Do not request a clean shutdown, kill the container immediately.

    `--dont-kill`
      If the clean shutdown does not finish in *timeout* seconds, exit with
      error, do not kill the container.

    `-t`, `--timeout` *timeout*
      How many seconds to wait for the container to cleanly shutdown before
      killing it or failing, depending on whether option `--dont-kill` is set.
      The default timeout is *60* seconds.

`ct attach` [*options*] *ctid*, `ct enter` [*options*] *ctid*
  Attach container *ctid* and open a shell. `osctld` tries to open `bash`,
  `busybox` and falls back to `/bin/sh`. The shell is not reading any personal
  configuration files from within the container in order to provide a unified
  shell interface across all containers. Use option `--user-shell` to change
  this behaviour.

    `-u`, `--user-shell`
      Load the shell that's configured in the container's `/etc/passwd` for
      `root` and read personal configuration files, such as `.bashrc`.

`ct console` [*options*] *ctid*
  Attach container console. Unlike in LXC, this console is persistent across
  container reboots. It can be attached even when the container is stopped.
  The console can be detached using **Ctrl-a q**.

  If global option `-j`, `--json` is set, the console will not manipulate the
  TTY, but instead will accept JSON commands on standard input. Output from the
  console will be written to standard output as-is. To detach the console, send
  `SIGTERM` to `osctl`. To learn more about the JSON commands, see
  `CONSOLE INTERFACE`.

    `-t`, `--tty` *n* - Select which TTY to attach, defaults to **0**.

`ct exec` [*options*] *ctid* *cmd...*
  Attach container *ctid* and execute command *cmd* within a shell.
  stdin/stdout/stderr of *cmd* is piped to your current shell.

    `-r`, `--run-container`
      If the container isn't already running, start it, but run *cmd* instead
      of the container's init system. `lxc-init` is run as PID 1 to reap child
      processes and to run *cmd*. The container is stopped when *cmd* finishes.

    `-n`, `--network`
      If the container is started using the `-r`, `--run-container` option,
      configure the network before running *cmd*. Normally the network is
      brought up by the container's init system, for which `osctld` generates
      configuration files. Since `ct exec` does not use the container's init
      system when starting the container, the network is by default not
      configured.

      Note that only static IP address and route configuration can be setup
      in this way. DHCP client is not run.

`ct runscript` [*options*] *ctid* *script* [*arguments...*]
  Execute *script* within the context of container *ctid*.

    `-r`, `--run-container`
      If the container isn't already running, start it, but run *script* instead
      of the container's init system. `lxc-init` is run as PID 1 to reap child
      processes and to run *script*. The container is stopped when *script*
      finishes.

    `-n`, `--network`
      If the container is started using the `-r`, `--run-container` option,
      configure the network before running *cmd*. Normally the network is
      brought up by the container's init system, for which `osctld` generates
      configuration files. Since `ct exec` does not use the container's init
      system when starting the container, the network is by default not
      configured.

      Note that only static IP address and route configuration can be setup
      in this way. DHCP client is not run.

`ct set autostart` [*options*] *ctid*
  Start the container automatically when `osctld` starts or when its pool is
  imported.

    `-p`, `--priority` *n*
      Priority determines container start order. `0` is the highest priority,
      higher number means lower priority. Containers with the same priority
      are ordered by their ids. The default priority is `10`.

    `-d`, `--delay` *n*
      Time in seconds for which `osctld` waits until the next container is
      started. The default is `5` seconds.

`ct unset autostart` *ctid*
  Do not start the container automatically.

`ct set ephemeral` *ctid*
  Mark the container as ephemeral. An ephemeral container is destroyed when:

   - it is stopped using `ct stop`,
   - it is shutdown from within the container, e.g. using `halt`,
   - its pool is exported.

  An ephemeral container will not be destroyed when it is being stopped as
  a part of another `osctl` operation, such as `ct export`.

  Disabled by default.

`ct unset ephemeral` *ctid*
  Do not destroy the container after it is stopped.

`ct set distribution` *ctid* *distribution* *version* [*arch*]
  Change the information about the container's *distribution*, *version*
  and optionally *arch*. This information is used to configure the container's
  hostname, DNS resolver, networking, etc.

`ct set image-config` *ctid*
  Reapply container configuration from source container image, based on the
  container's distribution and version or the provided options. The image
  is searched for in remote repositories or can be provided as *file* using
  `--from-file`. Configuration values from the container image will replace
  current configuration.

  The container has to be stopped for this command to be allowed.

    `--from-file` *file*
      Use container image stored in *file*.

    `--distribution` *distribution*
      Distribution name in lower case, e.g. alpine, centos, debian, ubuntu.

    `--version` *version*
      Distribution version. The format can differ among distributions, e.g.
      alpine `3.6`, centos `7.0`, debian `9.0` or ubuntu `16.04`.

    `--arch` *arch*
      Container architecture, e.g. `x86_64` or `x86`. Defaults to the host system
      architecture.

    `--vendor` *vendor*
      Vendor to be selected from the remote image repository.

    `--variant` *variant*
      Vendor variant to be selected from the remote image repository.

    `--repository` *repository*
      Instead of searching all configured repositories from appropriate pool,
      use only repository *name*. The selected repository can be disabled.

`ct set hostname` *ctid* *hostname*
  Set container hostname. *hostname* should be a FQDN (Fully Qualified Domain
  Name). Depending on distribution, the hostname is configured within
  the container and an entry is added to `/etc/hosts`. The hostname
  is configured on every container start.

`ct unset hostname` *ctid*
  Unset container hostname. `osctld` will not touch the container's hostname
  anymore.

`ct set dns-resolver` *ctid* *address...*
  Configure DNS resolvers for container *ctid*. At least one DNS resolver is
  needed. Given DNS resolvers are written to the container's `/etc/resolv.conf`
  on every start.

  Note that when you assign a bridged veth with DHCP to the container, it will
  override `/etc/resolv.conf` with DNS servers from DHCP server.

`ct unset dns-resolver` *ctid*
  Unset container DNS resolvers. `osctld` will no longer manipulate the
  container's `/etc/resolv.conf`.

`ct set nesting` *ctid*
  Enable LXC nesting for container *ctid*. The container needs to be restarted for
  the change to take effect. This command also sets AppArmor profile to
  `osctl-ct-nesting`.

`ct unset nesting` *ctid*
  Disable LXC nesting for container *ctid*. The container needs to be restarted for
  the change to take effect. If AppArmor profile `osctl-ct-nesting` is set, it
  is changed to `lxc-container-default-cgns`.

`ct set seccomp` *ctid* *profile*
  Configure path to the seccomp profile. The container needs to be restarted
  to use the new profile.

`ct unset seccomp` *ctid*
  Reset the seccomp profile to the default value, i.e.
  `/run/osctl/configs/lxc/common.seccomp`.

`ct set init-cmd` *ctid* *binary* [*arguments...*]
  Set path to the binary within the container's root filesystem to be used as
  init with optional arguments. Defaults to `/sbin/init`.

`ct unset init-cmd` *ctid*
  Unset custom path to the binary used as init and use the default value, which
  is `/sbin/init`.

`ct set raw lxc` *ctid*
  Append raw LXC configuration read from standard input to the *osctld* generated
  LXC configuration file.

`ct unset raw lxc` *ctid*
  Remove raw LXC configuration from the *osctld* generated LXC configuration
  file.

`ct set attr` *ctid* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for container *ctid*. Configured
  attributes can be read with `ct ls` or `ct show` using the `-o`, `--output`
  option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

  User attributes are stored in the container's config file. They are included
  in the tarball produced by `ct export` and transfered to other nodes by
  `ct send`.

`ct unset attr` *ctid* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of container *ctid*.

`ct set cpu-limit` *ctid* *limit*
  Configure CFS bandwidth control cgroup parameters to enforce CPU limit. *limit*
  represents maximum CPU usage in percents, e.g. `100` means the container can
  fully utilize one CPU core.

  This command is just a shortcut to `ct cgparams set`, two parameters are
  configured: `cpu.cfs_period_us` and `cpu.cfs_quota_us`. The quota is calculated
  as: *limit* / 100 \* *period*.

    `-p`, `--period` *period*
      Length of measured period in microseconds, defaults to `100000`,
      i.e. `100 ms`.

`ct unset cpu-limit` *ctid*
  Unset CPU limit. This command is a shortcut to `ct cgparams unset`.

`ct set memory` *ctid* *memory* [*swap*]
  Configure the maximum amount of memory and swap the container will be able to
  use. This command is a shortcut to `ct cgparams set`. Memory limit is set
  with cgroup parameter `memory.limit_in_bytes`. If swap limit is given as well,
  parameter `memory.memsw.limit_in_bytes` is set to *memory* + *swap*.

  *memory* and *swap* can be given in bytes, or with an appropriate suffix, i.e.
  `k`, `m`, `g`, or `t`.

`ct unset memory` *ctid*
  Unset memory limits. This command is a shortcut to `ct cgparams unset`.

`ct cp` *ctid* *new-id*
  Copy container *ctid* to *new-id*.

    `--[no-]consistent`
      When cloning a running container, it has to be stopped if the copy is to
      be consitent. Inconsistent copy will not contain data that the running
      container has in memory and have not yet been saved to disk by its
      applications. Enabled by default.

    `--pool` *pool*
      Name of the target pool. By default, container *new-id* is created on
      the same pool as container *ctid*.

    `--user` *user*
      Name of the target user. By default, the user of container *ctid* is used.
      When copying to a different pool, the target user has to exist before
      `ct cp` is run.

    `--group` *group*
      Name of the target group. By default, the group of container *ctid* is used.
      When copying to a different pool, the target group has to exist before
      `ct cp` is run.

    `--dataset` *name*
      Custom name of a dataset from the target pool, where the new container's
      root filesystem will be stored.

    `--no-network-interfaces`
      Remove network interfaces from the new container config. This is useful
      for cloning containers without duplicating network configuration.

`ct mv` *ctid* *new-id*
  Move container *ctid* to *new-id*. Can be used to move containers between pools
  or just to rename containers.

    `--pool` *pool*
      Name of the target pool. By default, container *new-id* is created on
      the same pool as container *ctid*.

    `--user` *user*
      Name of the target user. By default, the user of container *ctid* is used.
      When copying to a different pool, the target user has to exist before
      `ct cp` is run.

    `--group` *group*
      Name of the target group. By default, the group of container *ctid* is used.
      When copying to a different pool, the target group has to exist before
      `ct cp` is run.

    `--dataset` *name*
      Custom name of a dataset from the target pool, where the new container's
      root filesystem will be stored.

`ct chown` *ctid* *user*
  Move container *ctid* to user namespace *user*. The container has to be stopped
  first.

`ct chgrp` [*options*] *ctid* *group*
  Move container *ctid* to group *group*. The container has to be stopped first.

    `--missing-devices` `check`|`provide`|`remove`
      The container may require access to devices that are not available in the
      target group. This option determines how should `osctld` treat those
      missing devices. `check` means that if a missing device is found, an error
      is returned and the operation is aborted. `provide` will add missing
      devices to the target group and all its parent groups, it will also ensure
      sufficient access mode. `remove` will remove all unavailable devices from
      the container. The default mode is `check`.

`ct boot` [*options*] *ctid*
  Start the container a from selected container image. The container's root
  dataset is bypassed and untouched. All container configuration is preserved,
  except the distribution info can be temporarily different. When the container
  is restarted, the temporary changes made by `ct boot` are forgotten
  and the container's root dataset will be used again.

  `ct boot` can start the container from an image from repository (use options
  `--distribution`, `--version`, etc.) or from a local file (use option
  `--from-file`). By default, `ct boot` will try to use the container's
  distribution info to find the appropriate container image and start it.

  This command can be used e.g. to troubleshoot a broken system on the container's
  root dataset.
  
    `--force`
      If the container is running, stop it and boot the new image.

    `--from-file` *file*
      Create the container from a container image.

    `--distribution` *distribution*
      Distribution name in lower case, e.g. alpine, centos, debian, ubuntu.

    `--version` *version*
      Distribution version. The format can differ among distributions, e.g.
      alpine `3.6`, centos `7.0`, debian `9.0` or ubuntu `16.04`.

    `--arch` *arch*
      Container architecture, e.g. `x86_64` or `x86`. Defaults to the host system
      architecture.

    `--vendor` *vendor*
      Vendor to be selected from the remote image repository.

    `--variant` *variant*
      Vendor variant to be selected from the remote image repository.

    `--repository` *repository*
      Instead of searching all configured repositories from appropriate pool,
      use only repository *name*. The selected repository can be disabled.

    `--mount-root-dataset` *dir*
      Mount the container's root dataset to *dir* inside the container.

`ct config reload` *ctid*
  Reload the container's configuration file from disk. The container has to be
  stopped for the reload to be allowed.

`ct config replace` *ctid*
  Replace the container's configuration file by data read from standard input.
  The entire configuration file is replaced and reloaded by *osctld*. The config
  file has to be in the correct format for the current `osctld` version and has
  to contain required options, otherwise errors may occur. This is considered
  a low level interface, since a lot of runtime checks is bypassed.

  The container has to be stopped when `ct config replace` is called.

`ct passwd` *ctid* *user* [*password*]
  Change password of *user* in container *ctid*. The user has to already exist.
  If *password* is not given as an argument, it is prompted for on stdin.
  The container has to be running for this command to work, as it is using
  `passwd` or `chpasswd` from the container's system.

`ct su` *ctid*
  Switch to the user of container *ctid* and cd to its LXC home. The shell
  is tailored only for container *ctid*, do not use it to manipulate any other
  containers, even in the same LXC home. Every container can have a different
  cgroup configuration, which would be broken.

  Also not that when a container is started from this shell using `lxc-start`,
  `ct console` for tty0 will not be functional.

`ct cd` [*options*] *ctid*
  Opens a new shell with changed current working directory, based on *options*.
  When no option is specified, the directory is changed to the container's
  rootfs. Close the shell to return to your previous session.
  
    `-l`, `--lxc`
      Go to LXC config directory
    
    `-r`, `--runtime`
      Go to */proc/<init_pid>/root*. The container must be running for the path
      to exist.

`ct log cat` *ctid*
  Write the contents of container *ctid* log to the stdout.

`ct log path` *ctid*
  Write the path to the log file of container *ctid* to stdout.

`ct reconfigure` *ctid*
  Regenerate LXC configuration.

`ct export` [*options*] *ctid* *file*
  Export container *ctid* into a tar archive *file*. The archive will contain
  the container's configuration, its user, group and data. The exported archive
  can later be imported on the same or a different node.

    `--[no-]consistent`
      Enable/disable consistent export. When consistently exporting a running
      container, the container is stopped, so that applications can gracefully
      exit and save their state to disk. Once the export is finished,
      the container is restarted.

    `--compression` *auto* | *off* | *gzip*
      Enable/disable compression of the dumped ZFS data streams. The default is
      *auto*, which uses compressed stream, if the dataset has ZFS compression
      enabled. If the compression is not enabled on the dataset, the stream
      will be compressed using *gzip*. *off* disables compression, but if
      ZFS compression is enabled, the data is dumped as-is. *gzip* enforces
      compression, even if ZFS compression is enabled.

`ct import` [*options*] *file*
  Import a container defined in archive *file*, which can be generated by
  `ct export`.

    `--as-id` *ctid*
      Import the container and change its id to *ctid*. Using this option, it is
      possible to import the same *file* multiple times, essentially cloning
      the containers.

    `--as-user` *name*
      Import the container as an existing user *name*. User configuration from
      *file* is not used.

    `--as-group` *name*
      Import the container into an existing group *name*. Group configuration
      from *file* is not used.

    `--dataset` *dataset*
      Use a custom dataset for the container's rootfs. The dataset and all its
      parents are created, if it doesn't already exist.

    `--missing-devices` `check`|`provide`|`remove`
      The imported container may require access to devices that are not configured
      on this system. This option determines how should `osctld` treat those missing
      devices. `check` means that if a missing device is found, an error is returned
      and the import is aborted. `provide` will add missing devices to all parent
      groups and ensure sufficient access mode. `remove` will remove all unconfigured
      devices from the container. The default mode is `check`.

`ct send` [*options*] *ctid* *destination*
  Send container to *destionation* vpsAdminOS node. This is equal to running
  `ct send config`, `ct send rootfs`, `ct send state` and
  `ct send cleanup` in succession.

    `-p`, `--port` *port*
      SSH port, defaults to `22`.

    `--passphrase` *passphrase*
      Provide passhprase if the destination node requires it for authentication.

    `--as-id` *ctid*
      Send the container with a different ID.

    `--as-user` *user*
      Send the container with a different user name. The user configuration
      remains the same, it is only the name that is changed.

    `--as-group` *group*
      Send the container with a different group name. The group configuration
      remains the same, it is only the name that is changed.

    `--to-pool` *pool*
      Select pool on the target node to send the container to. If not set, the
      target node uses its first available pool.

    `--clone`
      Do not move the container to *destination*, but clone it.

    `--no-consistent`
      When `--clone` is used, the container is by default stopped to store all
      state on disk. After a snapshot with all state is taken, the container
      is started again. `--no-consistent` can be used to clone the container
      while it is running.

    `--no-restart`
      Do not restart the container on this node after it is cloned to the target
      node.

    `--no-start`
      Do not start the container on the target node, keep it stopped.

    `--no-network-interfaces`
      Remove network interfaces from the container config sent to *destination*.
      This is useful for cloning containers without duplicating network
      configuration.

    `--no-snapshots`
      Do not send existing snapshots to *destination*. Only temporary snapshots
      created for the send process are sent.

`ct send config` [*options*] *ctid* *destination*
  Send config of container *ctid* to *destination*. *destination* is a host
  name or an IP address of another vpsAdminOS node. The container's user, group
  and config files are copied over SSH to *destination*.

    `-p`, `--port` *port*
      SSH port, defaults to `22`.

    `--passphrase` *passphrase*
      Provide passhprase if the destination node requires it for authentication.

    `--as-id` *ctid*
      Send the container with a different ID.

    `--as-user` *user*
      Send the container with a different user name. The user configuration
      remains the same, it is only the name that is changed.

    `--as-group` *group*
      Send the container with a different group name. The group configuration
      remains the same, it is only the name that is changed.

    `--to-pool` *pool*
      Select pool on the target node to send the container to. If not set, the
      target node uses its first available pool.

    `--no-network-interfaces`
      Remove network interfaces from the container config sent to *destination*.
      This is useful for cloning containers without duplicating network
      configuration.

    `--no-snapshots`
      Do not send existing snapshots to *destination*. Only temporary snapshots
      created for the send process are sent.

`ct send rootfs` *ctid*
  Continue sending of container *ctid* to previously configured
  *destination*. `ct send rootfs` takes snapshots of the container's datasets
  and sends them to the *destination*.

`ct send sync` *ctid*
  Send rootfs changes since `ct send rootfs` or the previous `ct send sync`.
  This send step is optional and can be used to keep the source and destination
  containers close until `ct send state` is called.

`ct send state` [*options*] *ctid*
  This command stops the container if it is running, makes another set of
  snapshots of the container's dataset and sends them to *destination*.
  The container is then started on the *destination* node.

    `--clone`
      Do not move the container to *destination*, but clone it.

    `--no-consistent`
      When `--clone` is used, the container is by default stopped to store all
      state on disk. `--no-consistent` can be used to clone the container while
      it is running.

    `--no-restart`
      Do not restart the container on this node after it is cloned to the target
      node.

    `--no-start`
      Do not start the container on the target node, keep it stopped.

`ct send cleanup` [*options*] *ctid*
  Perform a cleanup after container *ctid* was sent to another node. The send
  state is reset and the container is deleted unless it was cloned.

`ct send cancel` [*options*] *ctid*
  Cancel a send of container *ctid*. The send state is deleted from
  the source node, and all traces of the container are removed from the
  *destination* node. This command has to be called in-between send steps
  up until `ct send state`, it cannot stop the send if one of the
  steps is still in progress. `ct send cancel --force` can be used instead of
  `ct send cleanup` to keep the source container and drop the send state.

    `-f`, `--force`
      Cancel the send state on the local node, even if the remote node
      refuses to cancel. This is helpful when the send state between the
      two nodes gets out of sync. The remote node may remain in an unconsistent
      state, but from there, the container can be deleted using `osctl ct del`
      if needed.

    `-l`, `--local`
      Cancel the send state only on the local node, do not even attempt to
      contact the target node. The remote node may remain in an unconsistent
      state, but from there, the container can be deleted using `osctl ct del`
      if needed.

`ct monitor` *ctid*
  Monitor state changes of container *ctid* and print them on standard output.
  If global option `-j`, `--json` is used, the state changes are reported
  in JSON.

`ct wait` *ctid* *state...*
  Block until container *ctid* enters one of given states.

`ct top` [*options*]
  top-like TUI application showing running containers and their CPU, memory,
  ZFS objsets and network usage. `ct top` can function in two modes: *realtime*
  and *cumulative*. *realtime* mode shows CPU usage in percent and other
  resources as usage per second, except memory and the number of processes.
  *cumulative* mode shows all resource usage accumulated from the time `ct top`
  was started.

  Key bindings:

  Keys                      | Action
  ------------------------- | -------------
  `q`                       | Quit
  `<`, `>`, *left*, *right* | Change sort column
  `r`, `R`                  | Reverse sort order
  *up*, *down*              | Select containers
  *space*                   | Highlight selected container
  *enter*                   | Open htop and filter container processes
  `m`                       | Toggle between `realtime` and `cumulative` mode.
  `p`                       | Pause/unpause resource tracking.
  `?`                       | Show help message.

  When global option `-j`, `--json` is used, the TUI is replaced by JSON
  being periodically printed on standard output. Every line describing resource
  usage at the time of writing. `ct top` with JSON output can be manually
  refreshed by sending it `SIGUSR1`.

    `-r`, `--rate` *n*
      Refresh rate in seconds, defaults to 1 second.

`ct pid` [*pid...*] | `-`
  Find containers by process IDs. By default, the process IDs are passed as
  command-line arguments. If the first PID is `-`, the PIDs are read from
  standard input, one PID per line.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

`ct ps` *ctid*
  Filter processes belonging to container *ctid* without entering the container.

  Available parameters:

  - `pool` - pool name
  - `ctid` - container id
  - `pid` - process ID as seen on the host
  - `ctpid` - process ID as seen inside the container
  - `ruid` - real UID as seen on the host
  - `rgid` - real GID as seen on the host
  - `euid` - effective UID as seen on the host
  - `egid` - effective GID as seen on the host
  - `ctruid` - real user ID as seen inside the container
  - `ctrgid` - real group ID as seen inside the container
  - `cteuid` - effective user ID as seen inside the container
  - `ctegid` - effective group ID as seen inside the container
  - `vmsize` - virtual memory size
  - `rss` - resident set size
  - `state` - current process state, see proc(5)
  - `start` - process start time
  - `time` - time spent using CPU
  - `command` - full command string with arguments
  - `name` - command name (only executable)

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`ct assets` [*options*] *ctid*
  List container assets and their state.

    `-v`, `--verbose`
      Show detected errors.

`ct cgparams ls` [*options*] *ctid* [*parameters...*]
  List cgroup parameters for container *ctid*. If no *parameters* are provided,
  all configured parameters are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

    `-S`, `--subsystem` *subsystem*
      Filter by cgroup subsystem, comma separated.

    `-a`, `--all`
      Include parameters from parent groups up to root group.

`ct cgparams set` *ctid* *parameter* *value...*
  Set cgroup parameter *parameter* of container *ctid* to *value*. `osctld` will
  make sure this parameter is always set when the container is started. The
  parameter can be for example `cpu.shares` or `memory.limit_in_bytes`. cgroup
  subsystem is derived from the parameter name, you do not need to supply it.

  It is possible to set multiple values for a parameter. The values are written
  to the parameter file one by one. This can be used for example for the
  `devices` cgroup subsystem, where you may need to write to `devices.deny` and
  `devices.allow` multiple times.

    `-a`, `--append`
      Append new values, do not overwrite previously configured values for
      *parameter*.

`ct cgparams unset` *ctid* *parameter*
  Unset cgroup parameter *parameter* from container *ctid*. Selected cgroup
  parameters are reset, the rest is left alone and merely removed from `osctld`
  config.

  The following parameters are reset:

  - `cpu.cfs_quota_us`
  - `memory.limit_in_bytes`
  - `memory.memsw.limit_in_bytes`

`ct cgparams apply` *ctid*
  Apply all cgroup parameters defined for container *ctid*, its group and all
  its parent groups, all the way up to the root group.

`ct cgparams replace` *ctid*
  Replace all configured cgroup parameters by data in JSON read from standard
  input. The data has to be in the following format:

```
{
  "parameters": [
    {
      "subsystem": <cgroup subsystem>,
      "parameter": <parameter name>,
      "value": [ values ]
    }
    ...
  ]
}
```

`ct devices ls` [*options*] *ctid*
  List configured devices.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

`ct devices add` [*options*] *ctid* `block`|`char` *major* *minor* *mode* [*device*]
  Allow container *ctid* to use `block`/`char` device identified by the *major*
  and *minor* numbers, see mknod(1) for more information. *mode* determines
  what is the container allowed to do: `r` to read, `w` to write, `m` to call
  `mknod`. For now, unprivileged containers cannot call `mknod`, so allowing it
  here doesn't do anything.

  If *device* is provided, `osctld` will prepare the device node within the
  container's `/dev` during every container start.

  Devices added in this way are always promoted, see `ct devices promote`.

    `-p`, `--[no-]parents`
      The device that is being added has to be provided by all parent groups,
      up to the *root* group. When this switch is enabled, `osctld` will add
      the device to all parent groups that do not already have it.

`ct devices del` *ctid* `block`|`char` *major* *minor*
  Forbid the container to use specified device and remove its device node, if it
  exists.

`ct devices chmod` [*options*] *ctid* `block`|`char` *major* *minor* *mode*
  Change the access mode of the specified device to *mode*. The mode can be
  changed only if the container's group provides the device with all necessary
  access modes, or `-p`, `--parents` is used.

  If the device was inherited, it is promoted to a standalone device and saved
  into the config file with the modified access mode.

    `-p`, `--parents`
       Ensure that all parent groups provide the device with the required
       access mode. Parents that do not provide correct access modes are updated.

`ct devices promote` *ctid* `block`|`char` *major* *minor*
  Promoting a device will ensure that parent groups will have to provide it,
  it is a declaration of an explicit requirement. It will no longer be possible
  to remove the device from parent groups, without explicitly removing it from
  the container as well, e.g. using `group devices del -r`.

  Promoted devices are also exported together with the container, and on import,
  the target vpsAdminOS has to provide these devices as well, or forcefully
  remove them, see `ct export` and `ct import`.

  When sending containers with promoted devices, the target node has to
  provide those devices, otherwise the sending process will fail in the first
  step, i.e. `ct send config`.

`ct devices inherit` *ctid* `block`|`char` *major* *minor*
  Inherit the device from the parent group. This removes the explicit requirement
  on the pecified device, i.e. reverses `ct devices promote`. The access mode,
  if different from the group, will revert to the acess mode defined by the
  parent group.

  Note that if the parent group does not have the device set as inheritable,
  it will be removed from the container.

`ct devices replace` *name*
  Replace the configured devices by a new set of devices read from standard
  input in JSON. All devices read from the JSON will be promoted. The user
  is responsible for ensuring that the configured devices are provided by
  parent groups. Use other `ct devices` commands if you wish for `osctld`
  to enforce this rule.

  The data has to be in the following format:

```
{
  "devices": [
    {
      "dev_name": <optional device node>,
      "type": block|char,
      "major": <major number or asterisk>,
      "minor": <minor number or asterisk>,
      "mode": <combinations of r,w,m>,
      "inherit": true|false
    }
    ...
  ]
}
```

`ct prlimits ls` *ctid* [*limits...*]
  List configured resource limits. If no *limits* are provided, all configured
  limits are listed.

    `-H`, `--hide-header`
        Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct prlimits set` *ctid* *limit* *soft\_and\_hard*, `ct prlimits set` *ctid* *limit* *soft* *hard*
  Set resource *limit* on container *ctid*. Limit names and their descriptions
  can be found in setrlimit(2). The permitted names are the "RLIMIT\_" resource
  names in lowercase without the "RLIMIT\_" prefix, eg. `RLIMIT_NOFILE` should
  be specified as **nofile**.

  If *hard* is not provided, it equals to the *soft* limit. The value can be
  either an integer or **unlimited**.

`ct prlimits unset` *ctid* *limit*
  Unset resource *limit* from container *ctid*.

`ct netif ls` [*options*] [*ctid*]
  List configured network interfaces for all containers or a selected container
  *ctid*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `-l`, `--link` *bridge*
      Filter by linked bridge.

    `-t`, `--type` *type*
      Filter by interface type (`bridge` or `routed`)

`ct netif new bridge` [*options*] `--link` *bridge* *ctid* *ifname*
  Create a new bridge network interface in container *ctid*. This will create
  a pair of veth interfaces, one on the host, one in the container. The veth
  on the host will be linked to *bridge*. The interface will appear as *ifname*
  within the container. *bridge* is not managed by `osctld`, it must be provided
  by the system administrator in advance.

  Currently, the container uses DHCP to configure the interface.
  The container has to be stopped for this command to be allowed.

    `--link` *bridge*
      What bridge should the interface be linked with, required.

    `--[no-]dhcp`
      If enabled, the container's interface will be setup by DHCP. This option
      controls DHCP client within the container for supported distributions.
      DHCP server must be provided by the host, e.g. using Nix option
      `networking.dhcpd`.

      When DHCP is disabled, you can assign IP addresses manually using
      `ct netif ip` commands.

      Enabled by default.

    `--gateway-v4` `auto`|`none`|*address*
      IPv4 gateway to use when DHCP is disabled. If set to `auto`, the primary
      address of the linked *bridge* is used as a gateway.

    `--gateway-v6` `auto`|`none`|*address*
      IPv6 gateway to use when DHCP is disabled. If set to `auto`, the primary
      address of the linked *bridge* is used as a gateway.

    `--hwaddr` *addr*
      Set a custom MAC address. Every **x** in the address is replaced by
      a random value. By default, the address is dynamically allocated.

`ct netif new routed` [*options*] *ctid* *ifname*
  Create a new routed network interface in container *ctid*. Like for **bridge**
  interface, a pair veth is created. The difference is that the veth is not part
  of any bridge. Instead, IP addresses and networks are routed to the container
  by configuring routes. For the routed addresses to be accessible in your
  network, you need to configure either static or dynamic routing on your
  machines. `osctld` will automatically setup appropriate routes on the host
  veth interface and generate configuration files for the container's network
  system. The interface will appear as *ifname* within the container.
  
  The container has to be stopped for this command to be allowed.

    `--hwaddr` *addr*
      Set a custom MAC address. Every **x** in the address is replaced by
      a random value. By default, the address is dynamically allocated.

`ct netif del` *ctid* *ifname*
  Remove interface *name* from container *ctid*.
  The container has to be stopped for this command to be allowed.

`ct netif rename` *ctid* *ifname* *new-ifname*
  Rename network interface. The container has to be stopped for this operation
  to pass.

`ct netif set` *ctid* *ifname*
  Change network interface properties. The container has to be stopped for this
  command to be allowed. Available options depend on interface type.

    `--link` *bridge*
      What bridge should the interface be linked with. Applicable only for
      bridged interfaces.

    `--enable-dhcp`
      Enables DHCP client within the container for supported distributions.
      DHCP server must be provided by the host, e.g. using Nix option
      `networking.dhcpd`. Applicable only for bridged interfaces.

    `--disable-dhcp`
      Disables DHCP client within the container. When disabled, IP addresses
      can be assigned manually using `ct netif ip` commands. Applicable only
      for bridged interfaces.

    `--gateway-v4` `auto`|`none`|*address*
      IPv4 gateway to use when DHCP is disabled. If set to `auto`, the primary
      address of the linked *bridge* is used as a gateway. Applicable only for
      bridged interfaces.

    `--gateway-v6` `auto`|`none`|*address*
      IPv6 gateway to use when DHCP is disabled. If set to `auto`, the primary
      address of the linked *bridge* is used as a gateway. Applicable only for
      bridged interfaces.

    `--hwaddr` *addr*
      Change MAC address. Every **x** in the address is replaced by
      a random value. Use `-` to assign the MAC address dynamically.

`ct netif ip add` [*options*] *ctid* *ifname* *addr*
  Add IP address *addr* to interface *ifname* of container *ctid*. `osctld` will
  setup routing in case of **routed** interface and add the IP address to the
  container's interface.

    `--no-route`
      For routed interfaces, a new route is created automatically, unless
      there is already a route that includes *addr*. This option prevents
      the route from being created. You will have to configure routing
      on your own using `ct netif route` commands.

    `--route-as` *network*
      Instead of routing *addr*, setup a route for *network* instead. This
      is useful when you're adding an IP address from a larger network
      and wish the entire network to be routed to the container.
      Applicable only for routed interfaces.

`ct netif ip del` [*options*] *ctid* *ifname* *addr*|`all`
  Remove IP address *addr* from interface *name* of container *ctid*.

  For routed interfaces, all routes that are routed via *addr* are deleted
  as well.

    `--[no-]keep-route`
      If there is a route that exactly matches the removed IP address, then this
      option determines whether the route is removed or not. Routes are removed
      by default. Applicable only for routed interfaces.

    `-v`, `--version` *n*
      If *addr* is `all`, these options can specify which IP versions should
      be removed. If no option is given, both IPv4 and IPv6 addresses are
      removed.

`ct netif ip ls` [*ctid* [*ifname*]]
  List IP addresses from all network interfaces, only those assigned to
  container *ctid* or only those of interface *ifname*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `-v`, `--version` *version*
      Filter by IP version.

`ct netif route add` [*options*] *ctid* *ifname* *addr*
  Route *addr* into the container. For the routed address to be reachable,
  one address from the network has to be added to *ifname* (`ct netif ip add`),
  or you can route *addr* via another *hostaddr* that is already on *ifname*
  using option `--via`. Applicable only for routed interfaces.

    `--via` *hostaddr*
      Route *addr* via *hostaddr*. *hostaddr* must be a host IP address on
      *ifname* that has already been added using `ct netif ip add`.

`ct netif route del` [*options*] *ctid* *ifname* *addr*|`all`
  Remove routed address from a routed interface.

    `-v`, `--version` *n*
      If *addr* is `all`, these options can specify which IP versions should
      be removed. If no option is given, both IPv4 and IPv6 routes are
      removed.

`ct netif route ls` [*ctid* [*ifname*]]
  List configured routes from all routed interfaces, only those assigned to
  container *ctid* or only those of interface *name*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `-v`, `--version` *version*
      Filter by IP version.

`ct dataset ls` [*options*] *ctid* [*properties...*]
  List datasets of container *ctid*. *properties* is a space separated list of
  ZFS properties to read and print. Listed dataset names are relative to the
  container's root dataset, the root dataset itself is called `/`.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct dataset new` [*options*] *ctid* *dataset* [*mountpoint*]
  Create a new subdataset of the container's root dataset. The *dataset*
  is relative to the container's root dataset, e.g. in the default configuration,
  `osctl ct dataset new <id> var` will create ZFS dataset `<pool>/ct/<id>/var`
  and mount it to directory `/var` within the container. The target *mountpoint*
  can be optionally provided as an argument.

  Non-existing dataset parents are automatically created and mounted with respect
  to `--[no-]mount`.
  
  Created datasets are automatically shifted into the container's user namespace.
  Of course, container datasets can be managed using `zfs` directly. Required
  properties `uidmap` and `gidmap` are inherited by default.

  Datasets should be mounted using `ct mounts dataset`, mounts created with
  `ct mounts new` might not survive container export/import on different
  configurations.

    `--[no-]mount`
      Mount created datasets to the container, under the mountpoint of its
      parents or `/`. Created datasets are mounted to the container by default.

`ct dataset del` [*options*] *ctid* *dataset*
  Delete container subdataset *dataset*. The root dataset cannot be deleted.

    `-r`, `--recursive`
      Recursively delete all children as well. Disabled by default.

    `-u`, `--[no-]umount`, `--[no-]unmount`
      Unmount selected dataset and all its children when in recursive mode
      before the deletion. By default, mounted datasets will abort the deletion.

`ct mounts ls` *ctid*
  List mounts of container *ctid*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`ct mounts new` *options* *ctid*
  Create a new mount for container *ctid* described by *options*. The *fs* is not
  mounted immediately, but the next time the container starts.

    `--fs` *fs*
      File system or device to mount, required.

    `--mountpoint` *mountpount*
      Mountpoint within the container, required.

    `--type` *type*
      File system type, required.

    `--opts` *opts*
      Options, required. Standard mount options depending on the filesystem
      type, with two extra options from LXC: `create=file` and `create=dir`.

    `--[no-]automount`
      Activate this mount when the container starts. Enabled by default.

`ct mounts dataset` *options* *ctid* *dataset* *mountpoint*
  Mount subdataset *dataset* into container *ctid*. Only subdatasets of container
  *ctid* can be mounted in this way. Dataset mounts can survive container
  export/import or send to a host with different configuration. Mounts
  created via `ct mounts new` have a fixed *fs* path, which would change
  on a host with a zpool named differently and the container would refuse to
  start.

  In addition, `ct mounts dataset` does not mount the top-level directory, but
  rather a subdirectory called `private`. This prevents the container to access
  the `.zfs` special directory, which could be used to create or destroy
  snapshots from within the container.

    `--ro`, `--read-only`
      Mount the dataset in read-only mode.

    `--rw`, `--read-write`
      Mount the dataset in read-write mode. This is the default.

    `--[no-]automount`
      Activate this mount when the container starts. Enabled by default.

`ct mounts register` [*options*] *ctid* *mountpoint*
  Register a manually created mount. This can be used to register mounts created
  in `pre-mount` or `post-mount` script hooks (see `SCRIPT HOOKS`) or any other
  mount within the container that you wish to control. All options are optional,
  but unless you provide *fs* and *type*, you won't be able to use command
  `ct mounts activate`.

  `ct mounts register` works only on starting or running container. All mounts
  registered using this command will be forgotten once the container is stopped.

    `--fs` *fs*
      File system or device to mount.

    `--type` *type*
      File system type.

    `--opts` *opts*
      Mount options. Standard mount options depending on the filesystem
      type, with two extra options from LXC: `create=file` and `create=dir`.

    `--on-ct-start`
      Use this option if you're calling `ct mounts register` from script hooks,
      see `SCRIPT HOOKS`. Without this option, calling this command from hook
      scripts will cause a deadlock -- the container won't start and `osctld`
      will be tainted as well.

`ct mounts activate` *ctid* *mountpoint*
  Mount the directory inside the container. The container has to be running.
  Note that this command will mount the directory multiple times if called
  when the directory is already mounted.

`ct mounts deactivate` *ctid* *mountpoint*
  Unmount the directory from the running container.

`ct mounts del` *ctid* *mountpoint*
  Remove *mountpoint* from container *ctid*.

`ct recover kill` *ctid* [*signal*]
  Search and kill all processes of container *ctid*. Useful when even LXC is
  stuck. *signal* defaults to `SIGKILL`. After a container is killed in this
  way, it can be necessary to recover its state using `ct recover state`
  and cleanup its state using `ct recover cleanup`.

`ct recover state` *ctid*
  Force `osctld` to check status of container *ctid*.

  `osctld` checks container status only on startup and then watches for events
  from `lxc-monitor`. If the container dies in a way that the monitor does not
  report anything, `osctld` will not notice the change on its own and this
  command can be used to recover from such a state.

  `--no-lock`
    Ignore the manipulation lock mechanism. This can be used to forcefully
    recheck the container's state even if another command is operating on it.
    Use with caution. Can be used e.g. to wake up `osctl ct start` from waiting
    on a dead container.

`ct recover cleanup` [`-f`] *ctid*
  Remove any leftover cgroups and network interfaces that might have belonged
  to container *ctid*. This is useful when the container's management process
  crashes for some reason and does not cleanup after itself. This operation
  can be used only on stopped containers, unless `--force` is used.

    `-f`, `--force`
      Force cleanup of an unstopped container.

    `--cgroups`
      Cleanup only leftover cgroups.

    `--network-interfaces`
      Cleanup only network interfaces.

`group new` *options* *group*
  Create a new group for resource management.

    `--pool` *pool*
      Pool name, optional.

    `-p`, `--parents`
      Create all missing parent groups.

    `--cgparam` *parameter*=*value*
      Set cgroup parameter, may be used more than once. See `group cgparams set`
      for what the parameter is.

`group del` *group*
  Delete group *group*. The group musn't be used by any container.

`group ls` [*options*] [*groups...*]
  List available groups. If no *groups* are provided, all groups are listed.
    
    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `--pool` *names*
      Filter by pool, comma separated.

`group tree` *pool*
  Print the group hierarchy from *pool* in a tree.

`group show` *group*
  Show group info.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

`group set attr` *group* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for group *group*. Configured
  attributes can be read with `group ls` or `group show` using the `-o`, `--output`
  option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

`group unset attr` *group* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of group *group*.

`group cgparams ls` [*options*] *group* [*parameters...*]
  List cgroup parameters for group *group*. If no *parameters* are provided,
  all configured parameters are listed.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

    `-S`, `--subsystem` *subsystem*
      Filter by cgroup subsystem, comma separated.

    `-a`, `--all`
      Include parameters from parent groups up to root group.

`group cgparams set` *group* *parameter* *value...*
  Set cgroup parameter *parameter* of group *group* to *value*. `osctld` will
  make sure this parameter is always set when the container is started. The
  parameter can be for example `cpu.shares` or `memory.limit_in_bytes`. cgroup
  subsystem is derived from the parameter name, you do not need to supply it.

  It is possible to set multiple values for a parameter. The values are written
  to the parameter file one by one. This can be used for example for the
  `devices` cgroup subsystem, where you may need to write to `devices.deny` and
  `devices.allow` multiple times.

    `-a`, `--append`
      Append new values, do not overwrite previously configured values for
      *parameter*.

`group cgparams unset` *group* *parameter*
  Unset cgroup parameter *parameter* from group *group*. Selected cgroup
  parameters are reset, the rest is left alone and merely removed from `osctld`
  config.

  The following parameters are reset:

  - `cpu.cfs_quota_us`
  - `memory.limit_in_bytes`
  - `memory.memsw.limit_in_bytes`

`group cgparams apply` *group*
  Apply all cgroup parameters defined for group *group* and all its parent
  groups, all the way up to the root group.

`group cgparams replace` *group*
  Replace all configured cgroup parameters by data in JSON read from standard
  input. The data has to be in the following format:

```
{
  "parameters": [
    {
      "subsystem": <cgroup subsystem>,
      "parameter": <parameter name>,
      "value": [ values ]
    }
    ...
  ]
}
```

`group devices ls` [*options*] *group*
  List configured devices.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output, comma separated. Defaults to a selected
      subset of available parameters.

`group devices add` [*options*] *group* `block`|`char` *major* *minor* *mode* [*device*]
  Allow containers in *group* to use `block`/`char` device identified by
  the *major* and *minor* numbers, see mknod(1) for more information. *mode*
  determines what is the container allowed to do: `r` to read, `w` to write,
  `m` to call `mknod`.

  If *device* is provided, `osctld` will prepare the device node within the
  container's `/dev` during every container start.

    `-i`, `--[no-]inherit`
      Determines whether child groups and containers should inherit the device,
      i.e. be allowed to use it with the same access *mode*.

    `-p`, `--[no-]parents`
      The device that is being added has to be provided by all parent groups,
      up to the *root* group. When this switch is enabled, `osctld` will add
      the device to all parent groups that do not already have it.

`group devices del` *group* `block`|`char` *major* *minor*
  Forbid containers in *group* to use specified device and remove its device node,
  if it exists. If the device is used by any descendant groups or containers, it
  can be deleted only with the `-r`, `--recursive` switch.

    `-r`, `--recursive`
      Delete the device from all child groups and containers.

`group devices chmod` [*options*] *group* `block`|`char` *major* *minor* *mode*
  Change the access mode of the specified device to *mode*. The mode can be
  changed only if all parent groups provide the device with all necessary
  access modes and if no child group or container has broader access mode
  requirements. Use `-p`, `--parents` or `-r`, `--recursive` to override
  parent or child groups and containers.

  If the device was inherited, it is promoted to a standalone device and saved
  into the config file with the modified access mode.

    `-p`, `--parents`
      Ensure that all parent groups provide the device with the required
      access mode. Parent groups that do not provide correct access modes
      are updated and the missing access modes are set.

    `-r`, `--recursive`
      Change the access mode of all child groups and containers.

`group devices promote` *group* `block`|`char` *major* *minor*
  Promoting a device will ensure that parent groups will have to provide it,
  it is a declaration of an explicit requirement. It will no longer be possible
  to remove the device from parent groups, without explicitly removing it from
  this group as well, e.g. using `group devices del -r`.

`group devices inherit` *group* `block`|`char` *major* *minor*
  Inherit the device from the parent group. This removes the explicit requirement
  on the pecified device, i.e. reverses `ct devices promote`. The access mode,
  if different from the parent, will revert to the acess mode defined by the
  parent group.

  Note that if the parent group does not have the device set as inheritable,
  the device will be removed. This command cannot be used for the `root` group,
  as it has no parent to inherit from.

`group devices set inherit` *group* `block`|`char` *major* *minor*
  Set specified device as inheritable. Child groups and container will inherit
  this device immediately.

`group devices unset inherit` *group* `block`|`char` *major* *minor*
  Prevent the specified device from being automatically inherited by child
  groups and containers. The device is immediately removed from all child groups
  and containers, that have previously inherited it. Promoted devices are left
  alone.

`group devices replace` *group*
  Replace the configured devices by a new set of devices read from standard
  input in JSON. All devices read from the JSON will be promoted. The user
  is responsible for ensuring that the configured devices are provided by
  parent groups and that removed devices are not needed by child groups or
  containers. Use other `group devices` commands if you wish for `osctld`
  to enforce these rules.

  The data has to be in the following format:

```
{
  "devices": [
    {
      "dev_name": <optional device node>,
      "type": block|char,
      "major": <major number or asterisk>,
      "minor": <minor number or asterisk>,
      "mode": <combinations of r,w,m>,
      "inherit": true|false
    }
    ...
  ]
}
```

`group set cpu-limit` *group* *limit*
  Configure CFS bandwidth control cgroup parameters to enforce CPU limit. *limit*
  represents maximum CPU usage in percents, e.g. `100` means the container can
  fully utilize one CPU core.

  This command is just a shortcut to `group cgparams set`, two parameters are
  configured: `cpu.cfs_period_us` and `cpu.cfs_quota_us`. The quota is calculated
  as: *limit* / 100 \* *period*.

    `-p`, `--period` *period*
      Length of measured period in microseconds, defaults to `100000`,
      i.e. `100 ms`.

`group unset cpu-limit` *group*
  Unset CPU limit. This command is a shortcut to `group cgparams unset`.

`group set memory` *group* *memory* [*swap*]
  Configure the maximum amount of memory and swap the group will be able to
  use. This command is a shortcut to `group cgparams set`. Memory limit is set
  with cgroup parameter `memory.limit_in_bytes`. If swap limit is given as well,
  parameter `memory.memsw.limit_in_bytes` is set to *memory* + *swap*.

  *memory* and *swap* can be given in bytes, or with an appropriate suffix, i.e.
  `k`, `m`, `g`, or `t`.

`group unset memory` *group*
  Unset memory limits.

`group assets` [*options*] *group*
  List group's assets (datasets, files, directories) and their state.

    `-v`, `--verbose`
      Show detected errors.

`send key gen` [*options*]
  Generate public/private key pair that is used when sending containers to
  other vpsAdminOS nodes.

    `-t`, `--type` `rsa` | `ecdsa` | `ed25519`
      Key type, defaults to `rsa`.

    `-b`, `--bits` *bits*
      Specifies the number of bits in the key to create. Defaults to `4096` for
      `rsa` and `591` for `ecdsa`.

    `-f`, `--force`
      Overwrite the keys if they already exist.

`send key path` [`public` | `private`]
  Print the path to either the `public` or `private` key. Defaults to the
  `public` key.

`receive authorized-keys ls`
  List keys that are authorized to send containers to this node.

`receive authorized-keys add` [*options*] *name*
  Authorize given key to send containers to this node. The key is read from
  the standard input and must be provided on a single line.

    `--ctid` *pattern*
      Accept only containers whose ID matches the pattern.

    `--from` *pattern-list*
      Allow connections only from selected hosts. Multiple patterns can be
      separated by comma. Patterns are matched against source host address
      and reverse record.

    `--single-use`
      Remove the key after it is used to migrate a container onto this node.

    `--passphrase` *passphrase*
      In addition to the public key authentication, the sender must provide
      this passphrase. The passphrase can be used to differentiate identical
      keys with different names, the key with matching passphrase is used.

`receive authorized-keys del` *name*
  Remove the key identified by its *name*.

`repository ls` [*options*] [*repository...*]
  List configured repositories, from which container images are downloaded.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

`repository show` *repository*
  Show repository parameters.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.

    `-o`, `--output` *parameters*
      Select parameters to output.

`repository add` *repository* *url*
  Add *repository* with *url* to the default or the selected pool. The pool can
  be selected using global option `--pool`.

`repository del` *repository*
  Remove *repository* from the default or the selected pool.

`repository enable` *repository*
  Enable *repository*. Enabled repositories are searched for images 
  when creating containers. Repositories are enabled by default upon addition.

`repository disable` *repository*
  Disable *repository*. Disabled repositories are not searched for images,
  until reenabled.

`repository set url` *repository* *url*
  Change URL of *repository* to *url*.

`repository set attr` *repository* *vendor*:*key* *value*
  Set custom user attribute *vendor*:*key* for *repository*. Configured
  attributes can be read with `repository ls` or `repository show` using
  the `-o`, `--output` option.

  The intended attribute naming is *vendor*:*key*, where *vendor* is a reversed
  domain name and *key* an arbitrary string, e.g.
  `org.vpsadminos.osctl:declarative`.

`repository unset attr` *repository* *vendor*:*key*
  Unset custom user attribute *vendor*:*key* of *repository*.

`repository assets` *repository*
  Show repository's assets and their state.

`repository images ls` [*option*] *repository*
  List images available in *repository*.

    `-H`, `--hide-header`
      Do not show header, useful for scripting.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

    `--vendor` *vendor*
      Filter by vendor.

    `--variant` *variant*
      Filter by variant.

    `--arch` *arch*
      Filter by architecture.

    `--distribution` *distribution*
      Filter by distribution.

    `--version` *version*
      Filter by distribution version.

    `--tag` *tag*
      Filter by version tag.

    `--cached`
      Show only locally cached images.

    `--uncached`
      Show only locally uncached images.

`monitor`
  Print all events reported by `osctld` to standard output. If global option
  `-j`, `--json` is used, the events are printed in JSON.

`history` [*pool...*]
  Print management history of all or selected pools. If global option
  `-j`, `--json` is used, the events are printed in JSON.

`assets` [*options*]
  List `osctld` assets (datasets, files, directories) and their state.

    `-v`, `--verbose`
      Show detected errors.

`healthcheck` [*options*] [*pool...*]
  Verify `osctld` assets and optionally also assets of selected pools, which
  include all user, group and container assets stored on selected pools.

    `-a`, `--all`
      Verify all pools.

`ping` [*wait*]
  Attempt to connect to `osctld` to check if it is running. Without *wait*,
  `osctl ping` either succeeds or fails immediately. If *wait* is `0`, `osctl`
  will block until `osctld` becomes responsive. If *wait* is a positive number,
  `osctl` will wait for `osctld` for up to *wait* seconds.

  Exit values:

  - `0` Success
  - `1` Unspecified error
  - `2` Unable to connect to `osctld`
  - `3` Connected, but received unexpected response

`activate` [*options*]
  Configure the system after it was upgraded, i.e. the new system closure
  has been activated.

    `--[no-]system`
      NixOS overwrites files it thinks it manages, such as
      `/etc/sub{u,g}id` and `/etc/lxc/lxc-usernet`. If this option is enabled,
      the required files are regenerated. Enabled by default.

    `--[no-]lxcfs`
      In case LXCFS was reloaded, it is necessary to access `/proc/stat` and
      `/proc/loadavg` in all containers, in order for LXCFS to start tracking
      them. Enabled by default.

`shutdown` [`-f`|`--force`]
  Export all pools and stop all containers. This command should be used at
  system shutdown. Since all pools are immediately disabled, no container can be
  started. All running containers are stopped. System users and groups are left
  alone. `osctld` itself will remain functional.

  When shutdown is requested, file `/run/osctl/shutdown` is created. As long as
  this file exists, `osctld` will not auto-start containers and all pools will
  be disabled on import. When `osctld` prepares the system for shutdown, it sets
  the executable by owner permission on `/run/osctl/shutdown`.

  Unless option `-f`, `--force` is set, `osctl shutdown` will ask for
  confirmation on standard input to prevent accidents.

    `-f`, `--force`
      Do not ask for confirmation on standard input, initiate shutdown
      immediately.

`help` [*command...*]
  Shows a list of commands or help for one command

## SCRIPT HOOKS
`osctld` can execute user-defined scripts when containers are being started
or stopped. Script hooks are located at `/<pool>/hook/ct/<ctid>/<hook>`, use
`ct assets` to get the exact path for your container. In order for script hooks
to be called, they need to be executable. All script hooks are run as `root`
on the host, but mount namespace may differ, see below.

Note that many `osctl` commands called from script hooks will not work as expected
and may cause deadlocks. The hooks are run when the container is locked within
`osctld`, so if another `osctl` process called from a hook needs the lock,
a deadlock occurs. You should avoid calling `osctl` from hooks.

`pre-start`
  `pre-start` hook is run in the host's namespace before the container is mounted.
  The container's cgroups have already been configured and distribution-support
  code has been run. If `pre-start` exits with a non-zero status, the container's
  start is aborted.

`veth-up`
  `veth-up` hook is run in the host's namespace when the veth pair is created.
  Names of created veth interfaces are available in environment variables
  `OSCTL_HOST_VETH` and `OSCTL_CT_VETH`. If `veth-up` exits with a non-zero
  status, the container's start is aborted.

`pre-mount`
  `pre-mount` is run in the container's mount namespace, before its rootfs is
  mounted. The path to the container's runtime rootfs is in environment variable
  `OSCTL_CT_ROOTFS_MOUNT`. If `pre-mount` exits with a non-zero status, the
  container's start is aborted.

`post-mount`
  `post-mount` is run in the container's mount namespace, after its rootfs
  and all LXC mount entries are mounted. The path to the container's runtime
  rootfs is in environment variable `OSCTL_CT_ROOTFS_MOUNT`. If `post-mount`
  exits with a non-zero status, the container's start is aborted.

`on-start`
  `on-start` is run in the host's namespace, after the container has been
  mounted and right before its init process is executed. If `on-start` exits
  with a non-zero status, the container's start is aborted.

`post-start`
  `post-start` is run in the host's namespace after the container entered state
  `running`. The container's init PID is passed in environment varible
  `OSCTL_CT_INIT_PID`. The script hook's exit status is not evaluated.

`pre-stop`
  `pre-stop` hook is run in the host's namespace when the container is being
  stopped using `ct stop`. If `pre-stop` exits with a non-zero exit status,
  the container will not be stopped. This hook is not called when the container
  is shutdown from the inside.

`on-stop`
  `on-stop` is run in the host's namespace when the container enters state
  `stopping`. The hook's exit status is not evaluated.

`veth-down`
  `veth-down` hook is run in the host's namespace when the veth pair is removed.
  Names of the removed veth interfaces are available in environment variables
  `OSCTL_HOST_VETH` and `OSCTL_CT_VETH`. The hook's exit status is not
  evaluated.

`post-stop`
  `post-stop` is run in the host's namespace when the container enters state
  `stopped`. The hook's exit status is not evaluated.

## Environment variables
All hooks have the following environment variables set:

- `OSCTL_HOOK_NAME`
- `OSCTL_POOL_NAME`
- `OSCTL_CT_ID`
- `OSCTL_CT_USER`
- `OSCTL_CT_GROUP`
- `OSCTL_CT_DATASET`
- `OSCTL_CT_ROOTFS`
- `OSCTL_CT_LXC_PATH`
- `OSCTL_CT_LXC_DIR`
- `OSCTL_CT_CGROUP_PATH`
- `OSCTL_CT_DISTRIBUTION`
- `OSCTL_CT_VERSION`
- `OSCTL_CT_HOSTNAME`
- `OSCTL_CT_LOG_FILE`

## CONSOLE INTERFACE
`osctl --json ct console` accepts JSON commands on standard input. Commands
are separated by line breaks (`\n`). Each JSON command can contain the following
values:

```
{
  "keys": base64 encoded data,
  "rows": number of terminal rows,
  "cols": number of terminal columns
}
```

`keys` is the data to be written to the console. `rows` and `cols` control
terminal size. Example commands:

```
{"keys": "Cg=="}\n
{"keys": "Cg==", "rows": 25, "cols": 80}\n
{"rows": 50, "cols": 120}\n
```

Where `Cg==` is `\n` (enter/return key) encoded in Base64. All values
are optional, but `rows` and `cols` have to be together and empty command
doesn't do anything.

## DEBUGGING
Exception backtraces in `osctl` can be enabled by settings environment variable
`GLI_DEBUG=true`, e.g. `GLI_DEBUG=true osctl ct ls`. This will not make `osctl`
more verbose, only print exceptions when it crashes.

`osctld` is logging either to syslog or to `/var/log/osctld`, depending on your
system configuration. `osctl` provides several commands you can use for
debugging purposes. These commands are not shown in `osctl` help message.

`debug threads ls`
  Print a list of threads in `osctld` and their backtraces. This can be useful
  to check if some operation hangs.

`debug locks ls` [`-v`]
  Print a list of internal locks that are held by threads. Useful for deadlock
  analysis.

    `-v`, `--verbose`
      Include also backtraces of lock holding threads.

`debug locks show` *id*
  Print information about a specific internal lock and the thread holding it.

## EXAMPLES
Install zpool `tank` into `osctld`:

`osctl pool install tank`

Create a user:

`osctl user new --map 0:666000:65536 myuser01`

Create a container:

`osctl ct new --user myuser01 --distribution alpine --version latest myct01`

Add bridged veth interface:

`osctl ct netif new bridge --link lxcbr0 myct01 eth0`

Start the container:

`osctl ct start myct01`

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osctl` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
