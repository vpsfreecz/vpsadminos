# Docker
[Docker] is a popular tool for running application containers. Docker is
supported on vpsAdminOS and works out-of-the-box, but with several known issues.

The latest Docker version can be installed by following the manual for your
distribution, e.g.
<https://docs.docker.com/install/linux/docker-ce/ubuntu/>.

## Known issues

 - Docker in Docker (DinD) does not work, it tries to mount `/sys/fs/security`,
   which is not possible in an unprivileged container.

[Docker]: https://www.docker.com
