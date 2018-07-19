# What is vpsAdminOS
vpsAdminOS is a lightweight operating system that serves as a hypervisor
for unprivileged Linux system containers. Running application containers is not
our goal. vpsAdminOS is purely a *live* distribution. It does not install
on disk, there's no system state stored anywhere. It's usually booted via
network using PXE.

# Architecture
vpsAdminOS is built on top of [Nix], [NixOS] and [nixpkgs]. Nix is a package
manager, NixOS is a distribution based on Nix and nixpkgs is the package
collection. We chose to make our own spin of NixOS, because NixOS relies on
systemd and we wanted to replace it with something simpler. The hypervisor's
only job is to mount storage, connect to network and run containers. systemd's
advanced features are not needed, vpsAdminOS uses [runit]. This approach was
pioneered by [not-os], which we reused.

vpsAdminOS relies heavily on [ZFS on Linux]. The hypervisor itself has no local
state, but all containers and their configuration is stored on ZFS pools.

Containers in vpsAdminOS are managed by a system daemon called *osctld* --
short for OS control daemon. Users do not work with *osctld* directly, but
through a command line interface called *osctl*. *osctld* uses [LXC] to start
and monitor the containers. [LXCFS] is used in containers to override certain
files in `/proc` based on cgroup values. Container processes are also restricted
by [AppArmor], since the Linux kernel is still not perfect in some regards.

# Design goals
vpsAdminOS is made for administrators. The people who have to get up during the
night and deal with unexpected problems. It's designed to be simple and easy to
debug. The boot process is made of several shell scripts, the few runit services
are short scripts as well. We've invested a lot of time into making
the administrator's life simpler, see the page about
[container administration](../containers/administration). For example, although
we have *osctld* to manage LXC seamlessly under the hood, LXC utilities are
still easily accessible, so that *osctld* is not in the way while debugging
issues.

vpsAdminOS is being developed by [vpsFree.cz], where we're currently using
[OpenVZ Legacy] to run virtual servers for our members. vpsAdminOS is intended
to fully replace OpenVZ by solutions available in upstream and our own utilities.

# About the user guide
For the purposes of this user guide, you don't need to be familiar with Nix
and NixOS, but it certainly helps. It's also good know the basics of ZFS -- e.g.
what is a zpool, dataset, or a snapshot. To use vpsAdminOS in production, you
definitely need to know how to use [Nix] with [nixpkgs], [NixOS] and most likely
[NixOps] as well. The learning curve is pretty steep, but we think it is well
worth it.

[Nix]: https://nixos.org/nix/
[NixOs]: https://nixos.org/
[nixpkgs]: https://nixos.org/nixpkgs/
[NixOps]: https://nixos.org/nixops/
[runit]: http://smarden.org/runit/
[not-os]: https://github.com/cleverca22/not-os
[ZFS on Linux]: http://zfsonlinux.org
[LXC]: https://linuxcontainers.org/lxc/
[LXCFS]: https://linuxcontainers.org/lxcfs/
[AppArmor]: https://en.wikipedia.org/wiki/AppArmor
[vpsFree.cz]: https://vpsfree.org
[OpenVZ Legacy]: https://wiki.openvz.org/Main_Page
