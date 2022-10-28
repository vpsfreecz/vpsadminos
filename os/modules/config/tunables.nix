{ configs, pkgs, lib, ... }:
with lib;
{
  boot.kernel.sysctl = {
    "fs.protected_hardlinks" = lib.mkDefault 1;
    "fs.protected_symlinks" = lib.mkDefault 1;

    "kernel.dmesg_restrict" = true;

    # TCP BBR congestion control
    "net.core.default_qdisc" = lib.mkDefault "fq";
    "net.ipv4.tcp_congestion_control" = lib.mkDefault "bbr";

    # Enable netfilter logs in all containers, otherwise won't show up in syslogns
    "net.netfilter.nf_log_all_netns" = lib.mkDefault true;

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
    # irb(main):001:0> (1048576 * 32 * 16) / 1024.0 / 1024
    # => 512.0 # minimal amount of memory in MB the container needs to start mysqld
    "fs.nr_open" = mkDefault (1048576 * 32);

    "fs.aio-max-nr" = mkDefault (3 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_queued_events" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_user_instances" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "fs.inotify.max_user_watches" = mkDefault (2 * 1024 * 1024 * 1024 - 1);
    "kernel.keys.maxkeys" = mkDefault 100000;
    "kernel.keys.maxbytes" = mkDefault 2500000;
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
    "vm.max_map_count" = mkDefault 262144;
    "vm.min_free_kbytes" = mkDefault (1 * 1024 * 1024);
    "vm.min_slab_ratio" = mkDefault 12;
    "vm.overcommit_ratio" = mkDefault 3200;
    "vm.swappiness" = mkDefault 0;
  };
}
