{ config, pkgs, lib, ... }:
with lib;
with lib.kernel;
let
  kernelVersion = config.boot.kernelVersion;
  whenKernelAtLeast = v: attrs:
    optionalAttrs (versionAtLeast kernelVersion v) attrs;
in
{
  boot.kernel.sysctl = {
    "fs.protected_hardlinks" = mkDefault 1;
    "fs.protected_symlinks" = mkDefault 1;

    "kernel.dmesg_restrict" = true;

    # TCP BBR congestion control
    "net.core.default_qdisc" = mkDefault "fq";
    "net.ipv4.tcp_congestion_control" = mkDefault "bbr";

    # Enable netfilter logs in all containers, otherwise won't show up in syslogns
    "net.netfilter.nf_log_all_netns" = mkDefault true;

    # Take *extra care* when changing fs.nr_open:
    #
    # On Ubuntu 18.04, systemd will set NOFILE prlimit to the value of fs.nr_open,
    # mysqld then uses this value, multiplies it by 16 and calls mmap().
    # If the host system has enough memory, the call will pass, but hit a memory
    # limit inside the container, leading to OOM kill. Make sure that
    # fs.nr_open * 16 does not exceed minimal container memory limits and leaves
    # enough space for other processes. To reproduce this particular issue, you
    # need a host system with more physical memory than fs.nr_open * 16 bytes
    # and a cgroup memory limit on a container set below the number. If the host
    # does not have the memory itself, mmap() will return ENOMEM and mysqld will
    # remain operational.
    #
    # irb(main):001:0> (1048576 * 4 * 16) / 1024.0 / 1024
    # => 64.0 # minimal amount of memory in MB the container needs to start mysqld
    #
    # Another issue with high NOFILE is in mount.nfs (at least on Debian 10),
    # which also uses the value to allocate memory using mmap().
    #
    # Until we find a way to decouple fs.nr_open from NOFILE prlimit, we must
    # keep it low.
    "fs.nr_open" = mkDefault (1048576 * 4);

    "fs.aio-max-nr" = mkDefault (3 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_queued_events" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_user_instances" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_user_watches" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "kernel.keys.maxkeys" = mkDefault 100000;
    "kernel.keys.maxbytes" = mkDefault 2500000;

    # One container needs at least 6 PTYs: 1 for lxc-start, 1 for pty-wrapper
    # and 4 are allocated by LXC by default. This limit also includes all terminals
    # from all containers, e.g. all SSH sessions.
    "kernel.pty.max" = mkDefault 16384;
    "kernel.pty.reserve" = mkDefault 1024;

    "kernel.threads-max" = mkDefault 4194304;
    "kernel.pid_max" = mkDefault 4194304;
    "net.ipv4.neigh.default.gc_thresh1" = mkDefault 2048;
    "net.ipv4.neigh.default.gc_thresh2" = mkDefault 4096;
    "net.ipv4.neigh.default.gc_thresh3" = mkDefault 8192;
    "net.ipv6.neigh.default.gc_thresh1" = mkDefault 2048;
    "net.ipv6.neigh.default.gc_thresh2" = mkDefault 4096;
    "net.ipv6.neigh.default.gc_thresh3" = mkDefault 8192;
    "net.ipv4.route.max_size" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "net.ipv6.route.max_size" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    # "vm.max_map_count" = mkDefault 1048576; # defined in NixOS >= 23.11
    "vm.min_free_kbytes" = mkDefault (1 * 1024 * 1024);
    "vm.min_slab_ratio" = mkDefault 12;
    "vm.overcommit_ratio" = mkDefault 3200;
    "vm.swappiness" = mkDefault 0;
  } // whenKernelAtLeast "6.9" {
    # Enable unprivileged eBPF as systemd uses the available functionality to
    # implement application-bound firewall.
    # Our kernel implements a coarse-enough time-rounding shield against
    # timing attacks. The downside is that we can't support eBPF programs
    # requiring precise timing.
    "kernel.unprivileged_bpf_disabled" = 0;
    "kernel.sysctl_unprivileged_bpf_time_adjust_nsec" = 5 * 1000 * 1000; # 5ms
  };
}
