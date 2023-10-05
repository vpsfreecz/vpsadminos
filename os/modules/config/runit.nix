{ lib, config, pkgs, ... }:
with lib;

let
  apparmor_paths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;
  apparmor_paths_include = concatMapStrings (s: " -I ${s}/etc/apparmor.d") apparmor_paths;
  profile = "${pkgs.lxc}/etc/apparmor.d/lxc-containers";
in
{
  environment.systemPackages = with pkgs; [
    mbuffer
  ];

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
    defcgroupv=${if config.boot.enableUnifiedCgroupHierarchy then "2" else "1"}
    cgroupv=$defcgroupv

    for o in $(cat /proc/cmdline); do
      case $o in
        1)
          runlevel=single
          ;;
        runlevel=*)
          set -- $(IFS==; echo $o)
          runlevel=$2
          ;;
        osctl.cgroupv=*)
          set -- $(IFS==; echo $o)
          cgroupv=$2
          ;;
      esac
    done

    ln -sfn /etc/runit/runsvdir/$runlevel /etc/runit/runsvdir/current
    ln -sfn /etc/runit/runsvdir/current /service
    mkdir -p /run/runit /run/runit/service
    ln -sf /run/runit/service /run/service

    # LXC
    mkdir -p /var/lib/lxc/rootfs

    # CGroups
    case "$cgroupv" in
      1) ;;
      2) ;;
      *)
        echo "Invalid cgroup version specified: 'osctl.cgroupv=$cgroupv', " \
             "falling back to v$defcgroupv"
        cgroupv=$defcgroupv
        ;;
    esac

    case "$cgroupv" in
      1)
        mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup

        mkdir /sys/fs/cgroup/cpuset
        mount -t cgroup -o cpuset cgroup /sys/fs/cgroup/cpuset

        mkdir /sys/fs/cgroup/cpu,cpuacct
        mount -t cgroup -o cpu,cpuacct cgroup /sys/fs/cgroup/cpu,cpuacct

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

        mkdir -p /sys/fs/cgroup/systemd/runit
        ln -sf /sys/fs/cgroup/systemd/runit /run/runit/cgroup.system
        ln -sf /sys/fs/cgroup/systemd/runit /run/runit/cgroup.service
        ;;
      2)
        mount -t cgroup2 cgroup2 /sys/fs/cgroup
        for c in `cat /sys/fs/cgroup/cgroup.controllers` ; do
          echo "+$c" >> /sys/fs/cgroup/cgroup.subtree_control
        done

        mkdir /sys/fs/cgroup/system
        for c in `cat /sys/fs/cgroup/system/cgroup.controllers` ; do
          echo "+$c" >> /sys/fs/cgroup/system/cgroup.subtree_control
        done

        mkdir /sys/fs/cgroup/system/init
        echo 1 >> /sys/fs/cgroup/system/init/cgroup.procs
        echo $$ >> /sys/fs/cgroup/system/init/cgroup.procs

        mkdir /sys/fs/cgroup/system/service
        for c in `cat /sys/fs/cgroup/system//service/cgroup.controllers` ; do
          echo "+$c" >> /sys/fs/cgroup/system/service/cgroup.subtree_control
        done

        ln -sf /sys/fs/cgroup/system /run/runit/cgroup.system
        ln -sf /sys/fs/cgroup/system/service /run/runit/cgroup.service
        ;;
    esac

    mkdir -p /run/osctl
    echo "$cgroupv" > /run/osctl/cgroup.version

    # BPF FS
    mount -t bpf bpf /sys/fs/bpf

    # securityfs
    mount -t securityfs securityfs /sys/kernel/security

    ${optionalString (config.security.apparmor.enable && config.security.apparmor.enableOnBoot) ''
    # AppArmor
    ${pkgs.apparmor-parser}/bin/apparmor_parser -rKv ${apparmor_paths_include} "${profile}"
    ''}

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
    hwclock -w
    osctl shutdown --force
    hwclock -w
    echo and down we go
  '';
}
