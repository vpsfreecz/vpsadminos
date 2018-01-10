# vpsAdminOS

Lightweight hypervisor for system Linux containers.

---

vpsAdminOS is an operating system that serves as a hypervisor for container
virtualization. It is based on [not-os](https://github.com/cleverca22/not-os/)
and NixOS.

vpsAdminOS was designed for purposes of [vpsFree.cz](https://vpsfree.org),
a non-profit association that provides virtual servers to its members. We were
using OpenVZ Legacy since 2009, but needed to upgrade to a newer kernel,
as modern Linux distributions stopped supporting the kernel. We seemed to have
different needs than what LXC/LXD provided, so decided to create our custom
toolset to manage the containers to bring us closer to the experience of OpenVZ
on newer kernels. vpsAdminOS is built on:

- Vanilla kernel (currently 4.14)
- AppArmor
- LXC, LXCFS
- CRIU
- runit
- BIRD
- ZFS
- osctl/osctld (userspace tools bundled with vpsAdminOS)

vpsAdminOS especially focuses on user namespaces (e.g. one namespace per
container) and CGroups for resource management. One can set resource limits
on single container or groups of containers, allowing for fine-grained control
and resource sharing. osctl/osctld is an abstraction on top of LXC, managing
system users, LXC homes, CGroups and system containers. ZFS is currently
the only supported file system, in which we have our custom patches for seamless
integration with user namespaces, i.e. user/group id mapping on the file system
level.
