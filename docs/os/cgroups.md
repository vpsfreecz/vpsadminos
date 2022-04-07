# Control groups
vpsAdminOS supports primarily cgroups mounted in a hybrid hierarchy: cgroupv1
is used for controllers and cgroupv2 only tracks processes. While the unified
hierarchy using only cgroupv2 is already usable, vpsAdminOS is missing device
access control and as such is not suitable for production.

## Container cgroups
Available cgroups hierarchies in the containers depend on the host system. If
the host uses the hybrid hierarchy, then containers must use it as well. If, on
the other hand, the host uses unified hierarchy, then containers must use it, too.

Containers with systemd are handled automatically. *osctld* adds or removes
systemd parameter `systemd.unified_cgroup_hierarchy` which controls its behaviour.

Containers without systemd need up-to-date init script from container images
provided by vpsAdminOS in order to support the unified hierarchy.

## Cgroupv2 support in distributions
The following distributions support cgroupv2:

 - Alpine Linux with up-to-date init script
 - CentOS / Alma Linux / Rocky Linux >= 8
 - Debian >= 9
 - Devuan with up-to-date init script
 - Fedora >= 31 (possibly older)
 - NixOS >= 19.03 (possibly older)
 - openSUSE Leap >= 15.1 (possibly older)
 - Ubuntu >= 18.04
 - Void Linux with up-to-date init script

Older distributions with systemd that does not support cgroupv2 will not start
on vpsAdminOS using the unified hierarchy.
