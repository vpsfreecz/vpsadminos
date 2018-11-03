# Docker
[Docker] is a popular tool for running application containers. It's supported
by vpsAdminOS with two caveats. First, containers that you want to run Docker in
have to use a different seccomp profile:

```
osctl ct set seccomp <id> /etc/lxc/config/common.seccomp
```

The default seccomp profile denies access to kernel keyring, but Docker
(more precicely runc used by Docker) needs access to the keyring by default.

The other caveat is that only VFS storage driver is available. That's because
the default overlay driver does not work on top of ZFS.

The latest Docker version can be installed by following the manual for your
distribution, e.g.
<https://docs.docker.com/install/linux/docker-ce/ubuntu/>.

[Docker]: https://www.docker.com
