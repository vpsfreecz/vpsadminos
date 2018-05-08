# Resource management
A container's CPU and memory usage, IO throttling, network priorities
and access to devices is managed using cgroups.

## Groups
*osctld* is managing all cgroup subsystems and lets you configure individual
cgroup parameters. Since cgroups are hierarchic, but spread into multiple
subsystems, *osctld* provides a concept of unified *groups*. These groups are
defined once using *osctl*, but they are created in all cgroup subsystems,
so every subsystem has the same hierarchy. Every container belongs to one of
the groups. There are always two groups present: the *root* group
and the *default* group. The *root* group is the parent of all groups,
it's called `/`. The *default* group is where new containers are put, unless
a different group is specified. Its name is `/default`.

cgroup parameters can be configured both for groups and containers. This let's
you put several containers into one group and set shared limits, or limit entire
group hierarchies.

Groups are managed by `osctl group` commands:

```bash
osctl group ls
POOL   NAME       MEMORY   CPU_TIME
tank   /          -        -
tank   /default   -        -
```

## Configuring limits
Two of the most frequently wanted limits are for memory and CPU usage.

## Memory limits
Memory limits can be set using `osctl group/ct set memory`, depending on whether
you wish to configure limits for entire groups or specific containers. When you
set a limit on a group, no child group or container can exceed it.

Let's set a limit on the *root* group, which will limit the total amount of
memory your containers can use. The command below will let all containers
together use up to 16 GB memory and 4 GB swap:

```shell
osctl group set memory / 16G 4G
```

You can also set limits on your containers:

```shell
osctl ct set memory myct01 2G 1G
```

You could create many such containers, even if the sum of their memory limits
exceed that of the *root* group, i.e. >16 GB. But the sum of the used memory
couldn't go over 16 GB.

Configured limits can be removed using `osctl group/ct unset memory`.

## CPU limits
Similar to memory limits, it is possible to limit CPU usage in percents, where
100 % means that the group/container can utilize one CPU core. Let's configure
some CPU limits:

```shell
osctl group set cpu-limit / 800
osctl ct set cpu-limit myct01 200
```

The commands above will ensure that all containers use 8 cores at max
and container `myct01` can use up to 2 cores.

CPU limits can be removed using `osctl group/ct unset cpu-limit`.

## Other cgroup parameters
Configuration of memory and CPU limits as described on this page is actually
just an abstraction on top of `osctl group/ct cgparams` commands, using which
you can configure individual cgroup parameters. `osctl group/ct set memory`
is configuring parameters `memory.limit_in_bytes`
and `memory.memsw.limit_in_bytes`, where as CPU limits configure
`cpu.cfs_period_us` and `cpu.cfs_quota_us`. If you'd like to configure other
cgroup parameters, see [resource management](/containers/resources.md).

Note that access to devices using the `device` cgroup is managed independently,
see [device management](/containers/devices.md).
