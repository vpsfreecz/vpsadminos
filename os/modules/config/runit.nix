{ lib, config, pkgs, ... }:
with lib;

let
  compat = pkgs.runCommand "runit-compat" {} ''
    mkdir -p $out/bin/
    cat << EOF > $out/bin/poweroff
#!/bin/sh
exec runit-init 0
EOF
    cat << EOF > $out/bin/reboot
#!/bin/sh
exec runit-init 6
EOF
    chmod +x $out/bin/{poweroff,reboot}
  '';

  apparmor_paths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;
  apparmor_paths_include = concatMapStrings (s: " -I ${s}/etc/apparmor.d") apparmor_paths;
  profile = "${pkgs.lxc}/etc/apparmor.d/lxc-containers";
in
{
  environment.systemPackages = [ compat ] ++ (with pkgs; [
    mbuffer
  ]);

  runit.stage1 = ''
    # load kernel modules
    for x in ${lib.concatStringsSep " " config.boot.kernelModules}; do
      modprobe $x
    done

    # Apply kernel parameters
    sysctl -w --system

    ip addr add 127.0.0.1/8 dev lo
    ip link set lo up

    # enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

    # disable DPMS on tty's
    echo -ne "\033[9;0]" > /dev/tty0

    # runit
    runlevel=${config.runit.defaultRunlevel}
    for o in $(cat /proc/cmdline); do
      case $o in
        1)
          runlevel=single
          ;;
        runlevel=*)
          set -- $(IFS==; echo $o)
          runlevel=$2
          ;;
      esac
    done

    ln -sfn /etc/runit/runsvdir/$runlevel /etc/runit/runsvdir/current
    ln -sfn /etc/runit/runsvdir/current /service
    mkdir /run/service

    # LXC
    mkdir -p /var/lib/lxc/rootfs

    # CGroups
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup

    mkdir /sys/fs/cgroup/cglimit
    mount -t cgroup -o cglimit cgroup /sys/fs/cgroup/cglimit

    mkdir /sys/fs/cgroup/cpuset
    mount -t cgroup -o cpuset cgroup /sys/fs/cgroup/cpuset

    mkdir /sys/fs/cgroup/cpu,cpuacct
    mount -t cgroup -o cpu,cpuacct cgroup /sys/fs/cgroup/cpu,cpuacct

    mkdir /sys/fs/cgroup/blkio
    mount -t cgroup -o blkio cgroup /sys/fs/cgroup/blkio

    mkdir /sys/fs/cgroup/memory
    mount -t cgroup -o memory cgroup /sys/fs/cgroup/memory
    echo 1 > /sys/fs/cgroup/memory/memory.use_hierarchy

    mkdir /sys/fs/cgroup/devices
    mount -t cgroup -o devices cgroup /sys/fs/cgroup/devices

    mkdir /sys/fs/cgroup/freezer
    mount -t cgroup -o freezer cgroup /sys/fs/cgroup/freezer

    mkdir /sys/fs/cgroup/net_cls,net_prio
    mount -t cgroup -o net_cls,net_prio cgroup /sys/fs/cgroup/net_cls,net_prio

    mkdir /sys/fs/cgroup/pids
    mount -t cgroup -o pids cgroup /sys/fs/cgroup/pids

    mkdir /sys/fs/cgroup/perf_event
    mount -t cgroup -o perf_event cgroup /sys/fs/cgroup/perf_event

    mkdir /sys/fs/cgroup/rdma
    mount -t cgroup -o rdma cgroup /sys/fs/cgroup/rdma

    mkdir /sys/fs/cgroup/hugetlb
    mount -t cgroup -o hugetlb cgroup /sys/fs/cgroup/hugetlb

    mkdir /sys/fs/cgroup/systemd
    mount -t cgroup -o name=systemd,none cgroup /sys/fs/cgroup/systemd

    mkdir /sys/fs/cgroup/unified
    mount -t cgroup2 cgroup2 /sys/fs/cgroup/unified

    # AppArmor
    mount -t securityfs securityfs /sys/kernel/security
    ${pkgs.apparmor-parser}/bin/apparmor_parser -rKv ${apparmor_paths_include} "${profile}"

    # DebugFS
    mount -t debugfs none /sys/kernel/debug/

    # /etc/fstab
    mount -a

    touch /etc/runit/stopit
    chmod 0 /etc/runit/stopit
  '';

  runit.stage2 = ''
    export PATH=/run/current-system/sw/bin
    exec runsvdir -P /service
  '';

  runit.stage3 = ''
    osctl shutdown --force
    hwclock -w
    echo and down we go
  '';
}
