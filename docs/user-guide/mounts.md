# Mounts

It is possible to mount directories from the host to containers. What makes this
complicated are [user namespaces](users.md). If the containers are to have
access to directories and files in the mountpoint, you need change their
ownership to match the container's user namespace. Sharing data between
containers in different user namespaces is not possible, as they cannot access
each other's data.

## Changing ownerships
Let's prepare a shared directory for containers using the same user namespace:

```bash
# Create a user
osctl user new --ugid 10000 --offset 888000 --size 65536 shareduserns

# Create a container
osctl ct new --user shareduserns --template ubuntu-16.04-x86_64-vpsfree.tar.gz myct01

# Prepare directory
mkdir -p /var/shared

# Create some test files
cd /var/shared
mkdir dir1 dir2
touch file1 file2 dir1/file dir2/file
```

Now we can bind-mount this directory to one or more containers:

```bash
osctl ct mounts new \
                    --fs /var/shared \
                    --type bind \
                    --opts bind,rw,create=dir \
                    --mountpoint mnt/shared \
                    myct01
```

Note that for the mount to appear, you need to restart the container.

```
osctl ct restart myct01
```

When you attempt to access those files from the container, you will not have
permission:

```bash
osctl ct attach myct01

root@myct01:/# ls -l /mnt/shared/
total 0
drwxr-xr-x 2 nobody nogroup 60 Jan 10 10:45 dir1
drwxr-xr-x 2 nobody nogroup 60 Jan 10 10:45 dir2
-rw-r--r-- 1 nobody nogroup  0 Jan 10 10:45 file1
-rw-r--r-- 1 nobody nogroup  0 Jan 10 10:45 file2

root@myct01:/# echo yay > /mnt/shared/file1 
bash: /mnt/shared/file1: Permission denied
```

As you can see, because the files are not in the container's user namespace,
it has no access. The files need to be chowned into the user namespace. Since
the user we created has `offset` set to `888000`, if we chown the files to
`888000:888000`, they will appear to be owned as root in the container.

```bash
chown -R 888000:888000 /var/shared

osctl ct attach myct01

root@myct01:/# ls -l /mnt/shared/
total 0
drwxr-xr-x 2 root root 60 Jan 10 10:45 dir1
drwxr-xr-x 2 root root 60 Jan 10 10:45 dir2
-rw-r--r-- 1 root root  0 Jan 10 10:45 file1
-rw-r--r-- 1 root root  0 Jan 10 10:45 file2

root@myct01:/# echo yay > /mnt/shared/file1
root@myct01:/# cat /mnt/shared/file1
yay
```

## ZFS UID/GID offsets
Changing ownership of all files and directories to share can take a long time,
depending on how many files you have. In fact, the same applies for the
container's rootfs. To avoid chowning files altogether, we patched our ZFS
to handle UID/GID mapping at runtime. Let's prepared a shared dataset for the
same user and container as above.

```bash
zfs create tank/shared
```

To enable UID/GID mapping, you can set `uidoffset` and `gidoffset` properties.
The value has to be the same as user's `offset`.

```bash
zfs unmount tank/shared
zfs set uidoffset=888000 gidoffset=888000 tank/shared
zfs mount tank/shared
```

Again, prepare some test files:

```bash
cd /tank/shared
mkdir dir1 dir2
touch file1 file2 dir1/file dir2/file
```

Mount into the container:

```bash
osctl ct mounts new \
                    --fs /tank/shared \
                    --type bind \
                    --opts bind,rw,create=dir \
                    --mountpoint mnt/shared \
                    myct01
osctl ct restart myct01
```

And the container has access to those files immediatelly:

```bash
osctl ct attach myct01

root@myct01:/# ls -l /tank/shared/
total 0
drwxr-xr-x 2 root root 60 Jan 10 10:45 dir1
drwxr-xr-x 2 root root 60 Jan 10 10:45 dir2
-rw-r--r-- 1 root root  0 Jan 10 10:45 file1
-rw-r--r-- 1 root root  0 Jan 10 10:45 file2

root@myct01:/# echo yay > /tank/shared/file1
root@myct01:/# cat /mnt/shared/file1
yay
```

The UID/GID offset can be changed without any cost, except that the dataset has
to be remounted. ZFS does not store mapped UIDs/GIDs on disk, the offseting
happens at runtime, based on the properties. If you send/receive the dataset
elsewhere, UIDs/GIDs will not be offset, unless you set `uidoffset`/`gidoffset`
properties on the target dataset as well.
