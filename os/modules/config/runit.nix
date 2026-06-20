{
  lib,
  config,
  pkgs,
  ...
}:
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

    # pam_lastlog
    mkdir -p /var/lib/lastlog

    # LXC
    mkdir -p /var/lib/lxc/rootfs

    # CGroups
    mkdir -p /run/osctl

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
        ;;
    esac

    mkdir -p /run/osctl/cgroup
    mount --rbind /sys/fs/cgroup /run/osctl/cgroup
    mount --make-rprivate /run/osctl/cgroup
    echo "$cgroupv" > /run/osctl/cgroup.version

    case "$cgroupv" in
      1)
        ln -sf /run/osctl/cgroup/systemd/runit /run/runit/cgroup.system
        ln -sf /run/osctl/cgroup/systemd/runit /run/runit/cgroup.service
        ;;
      2)
        # Kernfs filtering can hide sibling cgroups through /sys/fs/cgroup from
        # runit service wrappers. Use the private host view exported for osctld.
        ln -sf /run/osctl/cgroup/system /run/runit/cgroup.system
        ln -sf /run/osctl/cgroup/system/service /run/runit/cgroup.service
        ;;
    esac

    # BPF FS. Keep osctld's authoritative BPF mount under /run so container
    # mount namespace teardown cannot remove the daemon's pin filesystem.
    mkdir -p /run/osctl/bpf
    mount -t bpf bpf /run/osctl/bpf
    mount --make-rprivate /run/osctl/bpf
    mount --rbind /run/osctl/bpf /sys/fs/bpf
    mount --make-rprivate /sys/fs/bpf

    # TraceFS. Keep the host mount private and expose only the bounded
    # discovery files to containers through /run/osctl/tracing.
    mkdir -p /sys/kernel/tracing
    mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
    mount --make-rprivate /sys/kernel/tracing

    trace_dir=/run/osctl/tracing
    mkdir -p "$trace_dir"
    if ! mountpoint -q "$trace_dir"; then
      mount --bind "$trace_dir" "$trace_dir"
    fi
    mount -o remount,bind,rw "$trace_dir"
    mount --make-rprivate "$trace_dir"

    rm -f \
      "$trace_dir/available_filter_functions" \
      "$trace_dir/available_events" \
      "$trace_dir/pmu_type_kprobe" \
      "$trace_dir/pmu_type_uprobe"

    trace_exact_symbols="sched_fork wake_up_new_task tcp_v4_connect tcp_v6_connect tcp_set_state tcp_close inet_csk_accept udp_recvmsg udpv6_queue_rcv_one_skb free_user_ns retire_userns_sysctls"
    trace_syscalls="open openat openat2 kill tkill tgkill fork vfork clone clone3 execve execveat mount umount2 fsopen fsconfig fsmount move_mount open_tree mount_setattr read write pread64 pwrite64 stat lstat newfstatat statx connect accept accept4"
    trace_syscall_prefixes="__x64_sys_ __ia32_sys_ __arm64_sys_ __riscv_sys_ __s390x_sys_ __s390_sys_ __powerpc_sys_ __powerpc64_sys_ __sparc_sys_ __sparc64_sys_ __se_sys_ __do_sys_ sys_"

    ${pkgs.gawk}/bin/awk \
      -v exact="$trace_exact_symbols" \
      -v syscalls="$trace_syscalls" \
      -v prefixes="$trace_syscall_prefixes" '
        BEGIN {
          n = split(exact, exact_names, " ")
          for (i = 1; i <= n; i++)
            allow[exact_names[i]] = 1

          n = split(syscalls, syscall_names, " ")
          p = split(prefixes, prefix_names, " ")
          for (i = 1; i <= n; i++)
            for (j = 1; j <= p; j++)
              allow[prefix_names[j] syscall_names[i]] = 1
        }

        {
          name = $1
          if (allow[name] && !seen[name]++)
            print name
        }
      ' /sys/kernel/tracing/available_filter_functions \
      > "$trace_dir/available_filter_functions"
    : > "$trace_dir/available_events"
    if [ -r /sys/bus/event_source/devices/kprobe/type ]; then
      cat /sys/bus/event_source/devices/kprobe/type > "$trace_dir/pmu_type_kprobe"
    else
      : > "$trace_dir/pmu_type_kprobe"
    fi
    if [ -r /sys/bus/event_source/devices/uprobe/type ]; then
      cat /sys/bus/event_source/devices/uprobe/type > "$trace_dir/pmu_type_uprobe"
    else
      : > "$trace_dir/pmu_type_uprobe"
    fi

    chmod 0444 \
      "$trace_dir/available_filter_functions" \
      "$trace_dir/available_events" \
      "$trace_dir/pmu_type_kprobe" \
      "$trace_dir/pmu_type_uprobe"
    chmod 0555 "$trace_dir"
    mount -o remount,bind,ro "$trace_dir"

    # DebugFS projection. Containers must not see the raw host debugfs tree,
    # but older tracing tools still look for tracing below /sys/kernel/debug.
    debugfs_dir=/run/osctl/debugfs
    mkdir -p "$debugfs_dir"
    if ! mountpoint -q "$debugfs_dir"; then
      mount --bind "$debugfs_dir" "$debugfs_dir"
    fi
    mount -o remount,bind,rw "$debugfs_dir"
    mount --make-rprivate "$debugfs_dir"
    rm -rf "$debugfs_dir/tracing"
    ln -s ../tracing "$debugfs_dir/tracing"
    chmod 0555 "$debugfs_dir"
    mount -o remount,bind,ro "$debugfs_dir"

    # securityfs
    mount -t securityfs securityfs /sys/kernel/security
    mount --make-rprivate /sys/kernel/security

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
