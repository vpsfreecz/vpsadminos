# vpsAdminOS

Lightweight host for Linux system containers.

---

vpsAdminOS is an operating system that serves as a host for container
virtualization. It is based on [NixOS](https://nixos.org)
and [not-os](https://github.com/cleverca22/not-os/).

vpsAdminOS was designed for purposes of [vpsFree.cz](https://vpsfree.org),
a non-profit association that provides virtual servers to its members. We were
using OpenVZ Legacy since 2009, but needed to upgrade to a newer kernel,
as modern Linux distributions stopped supporting the OpenVZ Legacy kernel.

vpsAdminOS uses:

- [LTS kernel with a mix of out-of-tree patches](https://github.com/vpsfreecz/linux)
  to improve container experience,
- runit as an init system,
- ZFS for storage,
- our own tools for system container management called [osctl](https://man.vpsadminos.org/man8/osctl.8.html),
- LXC is used to run the containers,
- AppArmor for additional security,
- BIRD for network routing.

vpsAdminOS provides means to create and manage system containers, which look
and feel as much as a virtual machine as possible. It focuses on user
namespace and cgroup management to isolate the containers. All containers are
running as unprivileged. One can set resource limits on a single container
or groups of containers, allowing for fine-grained control and resource sharing.

*osctl* is an abstraction on top of LXC, managing system users, LXC
homes, cgroups and system containers. vpsAdminOS uses ZFS to store containers
and configuration.

## Links

* IRC: #vpsadminos @ irc.libera.chat
* Git: <https://github.com/vpsfreecz/vpsadminos>
* Man pages: <https://man.vpsadminos.org/>
* OS and program references: <https://ref.vpsadminos.org/>
* ISO images: <https://iso.vpsadminos.org/>
