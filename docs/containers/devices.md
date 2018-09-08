# Devices
Every container needs access to basic devices, such as `/dev/null`, `/dev/zero`,
TTYs, console, etc. Although access to these devices is managed through the
*devices* cgroup, manipulating the cgroup directly is tricky. You'd have to
add devices to the root group and then manually propagate them to child groups
and containers. To make device management and manipulation simpler, *osctld*
manages the devices itself. Use `osctl ct/group devices` instead of
`osctl ct/group cgparams` for device management.

## Device access trees
Since every container needs access to a minimal set of devices, we're utilizing
[groups](../user-guide/resources.md) to provide a common set of devices to
containers. Like with the *devices* cgroup, child groups can access only those
devices that the parent group has access to. Child groups can only restrict
access granted by the parent, not expand it. Therefore, every device that some
container wants to use must be enabled in the root group and then in all groups,
that are a direct or an indirect parent to that container.

Let's review the default device access list for the root group:

```shell
osctl group devices ls /
TYPE   MAJOR   MINOR   MODE   NAME           INHERIT   INHERITED 
char   1       3       rwm    /dev/null      true      -         
char   1       5       rwm    /dev/zero      true      -         
char   1       7       rwm    /dev/full      true      -         
char   1       8       rwm    /dev/random    true      -         
char   1       9       rwm    /dev/urandom   true      -         
char   5       0       rwm    /dev/tty       true      -         
char   5       1       rwm    -              true      -         
char   5       2       rwm    -              true      -         
char   136     all     rwm    -              true      -
```

This is the minimal set of devices that all containers have to have access to.
Child groups will inherit all devices where the `INHERIT` column is `true`,
making them available to their own child groups and containers.

If we look at the default group, which is a direct descendant of the root
group, we can see that all those devices were in fact inherited:

```shell
osctl group devices ls /default
TYPE   MAJOR   MINOR   MODE   NAME           INHERIT   INHERITED 
char   1       3       rwm    /dev/null      true      true      
char   1       5       rwm    /dev/zero      true      true      
char   1       7       rwm    /dev/full      true      true      
char   1       8       rwm    /dev/random    true      true      
char   1       9       rwm    /dev/urandom   true      true      
char   5       0       rwm    /dev/tty       true      true      
char   5       1       rwm    -              true      true      
char   5       2       rwm    -              true      true      
char   136     all     rwm    -              true      true
```

*osctld* makes sure that all these listed devices are actually enabled in the
*devices* cgroups and that the containers have corresponding device nodes
created.

## Adding a new device to all containers
If you wish to add a device to all containers, all you have to do is add it to
the root group and make it inheritable. All child groups and containers will
then be able to use it:

```shell
osctl group devices add --inherit / char 10 200 rw /dev/net/tun
```

Access to the device is permitted immediately, but the device node is created
the next time the container starts, when all the device nodes will be provided
by *osctld*. You can call `mknod` at any time though.

## Adding a new device to one group/container
When adding a new device to a non-root group or a container, the device has
to be provided by the parent groups, otherwise an error is reported:

```shell
osctl ct devices add myct01 char 10 229 rw /dev/fuse
error: device not available in group 'default'
```

You can either add the device to the parent groups manually, or you can use
the `-p`, `--parents` switch:

```shell
osctl ct devices add --parents myct01 char 10 229 r /dev/fuse
```

The device will then be enabled in all parent groups that do not already have it,
but only the one selected container will have access to it. The device will not
be automatically inherited to other groups or containers.

Since we have provided the device name, *osctld* has created the device node
within the container:

```shell
osctl ct exec myct01 ls -l /dev/fuse
crw-r--r--    1 root     root       10, 229 Mar  4 14:48 /dev/fuse
```

To add the device to a group, simply replace `osctl ct devices` with
`osctl group devices`.

## Inherited and promoted devices
When a device is marked as inheritable (i.e. the `INHERIT` column in
`osctl ct/group devices ls` is `true`), the device will automatically be
propagated to child groups and containers. Inherited devices can be provided
and taken away by the adminsitrator at any time. To declare an explicit
requirement of a device, or change its access mode, it has to be promoted.
The parent group then cannot simply remove the device, because its child group
or container has declared that it requires it.

Devices can be promoted by either by changing its access mode (see
[below](#changing-access-mode)) or `osctl ct/group device promote`. To remove
the requirement declaration, i.e. revert promotion, the device can be inherited
again using `osctl ct/group devices inherit`. Note that if the parent group
does not have the device marked as inheritable, the device will be removed from
the group or container you're manipulating and all child groups and containers.

To set or unset the inheritability flag, i.e. decide whether child groups and
containers should automatically inherit a device, you can use
`osctl group devices set/unset inherit`.

## Changing access mode
If you need to change access mode of an existing device, you can do so with
`osctl ct/group devices chmod`. By default, you can change the mode only when
it is safe, i.e.:

 - no child group or container is using the device with a broader access mode
 - all parent groups can provide the requested access mode

If you wish to override the child groups and containers, you can use switch
`-r`, `--recursive`, which will change all their modes as well. Similarly,
to update parent groups to provide necessary access mode, you can use switch
`-p`, `--parents`.

For example, we've created the `/dev/fuse` device above, but we've allowed only
read access to it. Let's add permission to write as well:

```shell
# This won't work, since both the default and root group only have `r`
osctl ct devices chmod myct01 char 10 229 rw
error: group 'default' provides only mode 'r'

# Add the missing permission to all parents:
osctl ct devices chmod --parents myct01 char 10 229 rw
```

## Removing devices
Devices can be removed only if no group or container uses them:

```shell
osctl group devices del / char 10 229
error: device is used by child groups/containers, use recursive mode
```

To remove the device from all child groups and containers, you can use switch
`-r`, `--recursive`:

```shell
osctl group devices del --recursive / char 10 229
```

By removing the device from the root group, we have removed it from all child
groups and all containers. If you remove a device from a non-root group or
a specific container, the parent groups can still use it.

It is not possible to remove an inherited device, because, as it is designed,
the device would automatically get inherited again when the pool is imported
again. You can, however, restrict access to inherited devices using
`osctl ct/group devices chmod`. To deny access completely, you can use mode `-`.

## Migrations, export/import
Since we're using device inheritance, we cannot ensure that a container will have
access to all expected devices when migrated or imported to another node with
different device hierarchy. *osctld* can check only for explicitly defined
devices for the container, i.e. non-inherited devices.

When importing a container, *osctld* will by default check that all required
devices are present. If not, the import is aborted. You can use option
`--missing-devices check|provide|remove` to change this behaviour.

Migrations enforce the *check* mode. All required devices have to be present,
or the migration will fail in the first step, i.e. `osctl ct migrate stage`.
It is up to the administrator to configure his vpsAdminOS nodes to provide
the same environment for migrations to work properly.
