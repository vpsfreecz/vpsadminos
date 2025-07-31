# Control groups
vpsAdminOS supports both cgroups v2 in a unified hierarchy and cgroups v1
in a hybrid hierarchy.

## Configuring cgroup hierarchy
vpsAdminOS defaults to the unified hierarchy, but optionally can be booted into
the hybrid hierarchy by setting `boot.enableUnifiedCgroupHierarchy = false;`.
Cgroup mode can also be changed using kernel parameter
[osctl.cgroupv](kernel-parameters.md#osctlcgroupv).

## Container cgroups
Available cgroups hierarchies in the containers depend on the host system. If
the host uses the unified hierarchy, then containers must use it as well. If, on
the other hand, the host uses hybrid hierarchy, then containers must use it, too.

Most distributions can still be used in both modes, except that older versions
might not support cgroups v2 and support for v1 is going to be dropped from systemd
eventually.

## Cgroups v2 support in distributions
The following distributions support cgroupv2:

 - Alpine Linux with up-to-date init script
 - CentOS / Alma Linux / Rocky Linux >= 8 (and also <= 6)
 - Chimera Linux
 - Debian >= 9 (and also <= 7)
 - Devuan with up-to-date init script
 - Fedora >= 31 (possibly older)
 - NixOS >= 19.03 (possibly older)
 - openSUSE Leap >= 15.1 (possibly older)
 - Ubuntu >= 18.04 (and also <= 14.04)
 - Void Linux with up-to-date init script

Older distributions with systemd that does not support cgroups v2 will not start
on vpsAdminOS using the unified hierarchy. Other older init systems usually don't
use cgroups at all and so there is no issue.
