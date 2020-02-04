{ configs, pkgs, lib, ... }:
with lib;
{
  boot.kernel.sysctl = {
    "fs.aio-max-nr" = mkDefault 200000;
    "fs.inotify.max_queued_events" = mkDefault 1048576;
    "fs.inotify.max_user_instances" = mkDefault 1048576;
    "fs.inotify.max_user_watches" = mkDefault 1048576;
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
    "vm.overcommit_ratio" = mkDefault 3200;
  };
}
