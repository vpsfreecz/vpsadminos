# cgroups

*osctld* is managing cgroups subsystems and hierarchy based on
[resource groups](../user-guide/resources.md). It ensures that every container
and management process is placed into the correct cgroup.

The cgroups hierarchy, as seen from the host:
 
    /sys/fs/cgroup/
    └── <subsystem>/
        └── osctl/
            └── pool.<pool name>/
                └── group.<group name>/
                    ├── [group.<subgroup name...>/]
                    │   └── <group contents...>
                    └── user.<user name>/
                        │── monitor/
                        └── ct.<container id>/
                            └── user-owned/

As you can see, all cgroups created by *osctld* are children of cgroup `osctl`.
Should you need to manipulate all containers from all pools, this is the place,
but you'd have to do it manually, as *osctld* is not actually configuring the
cgroup.

The *root* group, which can be seen and manipulated by *osctl* has path
`osctl/pool.<pool name>`. All other cgroups from the pool are children of this
cgroup. Child cgroups have their names prefixed with `group.`, as they can mix
with group/user cgroups.

Group/user cgroups are prefixed with `user.`. There is one group/user cgroup for
every combination of groups and users that have at least one container. These
cgroups exist mainly for *lxc-monitors*, which are used to track container state
changes and there is one monitor for each group/user combination.

Container cgroups are then prefixed with `ct.`. All cgroups, all the way down
to the container cgroup, are owned by root. This is to ensure that users
themselves cannot change cgroup limits on any cgroup that is managed by *osctld*.
Every container cgroup has a child cgroup called `user-owned`, which is chowned
to the container's user. This allows the container to create its own cgroups,
but they can't exceed nor change the limits defined by parent cgroups.
