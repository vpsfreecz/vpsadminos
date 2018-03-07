# OS requirements
*osctl* and *osctld* are designed to work on top of vpsAdminOS, but with a bit
of effort, it can be run on any other distribution with the appropriate
software. Of course, you'd have to do a lot of things manually, so it's not
recommended nor supported.

One use case for this is the development of *osctl*/*osctld*, which is done
on Ubuntu first, because vpsAdminOS is not so good with live code reloading.
For every change in the code, you'd have to build gems, deploy them to
a repository, rebuild the entire OS and boot it. That's much slower than just
restarting *osctld* from the updated code mounted over NFS.

## Software
- Kernel >=4.13
- LXC 2.1 with [custom patch](https://github.com/aither64/lxc/tree/vpsadminos-2.1)
    - enable network script.up hook for unprivileged containers:
      <https://github.com/aither64/lxc/commit/f4e86dfad30099bae3ab093b81d147280996d29e>
- ZFS on Linux >=0.7 with uid/gid offset [patch](https://github.com/aither64/zfs/tree/uid_offset)

## System changes
*osctld* needs to find LXC configs within `/etc/lxc`, as `/usr/share/lxc`
is not available in vpsAdminOS. In vpsAdminOS, needed directories are symlinked
from `/nix/store` into `/etc/lxc` when the OS is built, because *osctld* has no
way of knowing the path to LXC configs in `/nix/store` at runtime. On classic
distributions, the symlinks are created from `/usr/share/lxc`:

```bash
ln -s /usr/share/lxc/config /etc/lxc/config
ln -s config/common.conf.d /etc/lxc/common.conf.d
```

For container migrations to work, you need to create a new system user:

```bash
useradd -r -d /run/osctl/migration -s /bin/bash migration
```

Next, edit `/etc/ssh/sshd_config` and append the following:

```
Match User migration
  PasswordAuthentication no
  AuthorizedKeysFile /run/osctl/migration/authorized_keys
```

Another system user is used for template repository management:

```bash
useradd -r -d /run/osctl/repository -s /sbin/nologin repository
```
