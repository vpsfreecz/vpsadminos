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

    "fs.nr_open" = 1073741816;
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
