# Docker
[Docker] is a popular tool for running application containers. Docker is
supported on vpsAdminOS and works out-of-the-box, but with several known issues.

The latest Docker version can be installed by following the manual for your
distribution, e.g.
<https://docs.docker.com/install/linux/docker-ce/ubuntu/>.

## Known issues

 - Only the VFS storage driver is available. That's because the default overlay
   driver does not work on top of ZFS. This limitation makes Docker very slow
   when building containers.
 - Docker in Docker (DinD) does not work, it tries to mount `/sys/fs/security`,
   which is not possible in an unprivileged container.

[Docker]: https://www.docker.com
