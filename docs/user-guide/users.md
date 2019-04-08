# User namespaces

In vpsAdminOS, it is possible to run every container in a separate user
namespace. To achieve this, *osctld* manages system users, because there is
a limit on how many UID/GID mappings a single user can have. Every user can
have a different UID/GID mapping, which can be helpful in case a kernel bug
would allow users to leave their containers. If all containers are using
a different user namespace, they don't have access to each other's data, even
when the container is breached.

Every container belongs to one user and all containers are running as
unprivileged. Let's create a new user:

```bash
osctl user new --map 0:666000:65536 myuser01
```

Option `--map` specifies a mapping for user and group IDs. In this example, root
within the container will have UID `0`, which will be mapped to UID `666000`
on the host. There will be `65536` mapped user/group IDs, i.e. the container
will have IDs in range from `666000` to `666000+65536`. And finally, `myuser01`
is the user's name. The name is the user's identifier within *osctld*,
the system user's name is derived from it.

This is what *osctld* will manage for you regarding users:

 - system users in `/etc/passwd` and system groups in `/etc/group`
 - entries in `/etc/subuid`, `/etc/subgid` and `/etc/lxc/lxc-usernet` when using
   [networking](networking.md)
 - user home directories, safe access permissions

It is up to you how many users you create. You can use one user for all
containers, a different user for every container or anything in between. When
you have created at least one user, you can continue
with [container management](containers.md).
