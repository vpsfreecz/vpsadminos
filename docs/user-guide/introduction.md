# What is vpsAdminOS
vpsAdminOS is a lightweight operating system that serves as a host 
for unprivileged Linux system containers. System containers run the entire
userspace part of a Linux system and should look and feel as a virtual
machine. You can create a container with many distributions, such as CentOS,
Debian, Ubuntu and of course NixOS.

vpsAdminOS can be used as a *live* distribution and boot e.g. via network using
PXE, or it can be installed to disk.

# Architecture
vpsAdminOS is built on top of [Nix], [NixOS] and [nixpkgs]. Nix is a package
manager, NixOS is a distribution based on Nix and nixpkgs is the package
collection. We chose to make our own spin of NixOS, because NixOS relies on
systemd and we wanted to replace it with something simpler. The host's
only job is to mount storage, connect to network and run containers. systemd's
advanced features are not needed, vpsAdminOS uses [runit]. This approach was
pioneered by [not-os], which we reused.

vpsAdminOS relies heavily on [OpenZFS]. The host system has no local
state, but all containers and their configuration is stored on ZFS pools.

Containers in vpsAdminOS are managed by a system daemon called *osctld* --
short for OS control daemon. *osctld* can be controlled using a command line
interface called *osctl*.

vpsAdminOS uses [LTS Linux kernel with a mix of out-of-tree patches]. These
patches are essential, providing e.g. a syslog namespace to isolate kernel logs,
virtualized views of selected files in `/proc` and `/sys` and other tweaks.
Under the hood, *osctld* uses [LXC] to start and monitor the containers.
Container processes are also restricted by [AppArmor].

# Design goals
vpsAdminOS is made for administrators. The people who have to get up during the
night and deal with unexpected problems. It's designed to be hopefully simple
and easy to debug. The boot process is made of several shell scripts, the few
runit services are short scripts as well. We've invested a lot of time into making
the administrator's life simpler, see the page about
[container administration](../containers/administration.md). For example, although
we have *osctld* to manage LXC seamlessly under the hood, LXC utilities are
still easily accessible, so that *osctld* is not in the way while debugging
issues.

vpsAdminOS is being developed and used in production by [vpsFree.cz].

# About the user guide
For the purposes of this user guide, you don't need to be familiar with Nix
and NixOS, but it certainly helps. It's also good know the basics of ZFS -- e.g.
what is a zpool, dataset, or a snapshot. To use vpsAdminOS in production, you
definitely need to know how to use [Nix] with [nixpkgs], [NixOS].
The learning curve is pretty steep, but we think it is well worth it.

[Nix]: https://nixos.org/nix/
[NixOs]: https://nixos.org/
[nixpkgs]: https://nixos.org/nixpkgs/
[NixOps]: https://nixos.org/nixops/
[runit]: http://smarden.org/runit/
[not-os]: https://github.com/cleverca22/not-os
[OpenZFS]: https://openzfs.org
[LTS Linux kernel with a mix of out-of-tree patches]: https://github.com/vpsfreecz/linux
[LXC]: https://linuxcontainers.org/lxc/
[LXCFS]: https://linuxcontainers.org/lxcfs/
[AppArmor]: https://en.wikipedia.org/wiki/AppArmor
[vpsFree.cz]: https://vpsfree.org
