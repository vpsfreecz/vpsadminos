{ config, pkgs, lib, ... }:
{
  # import local configuration (local.nix) if it exists
  imports = [
    ../installer/cd-dvd/channel.nix
  ] ++ lib.optionals (lib.pathExists ../../configs/local.nix) [ ../../configs/local.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";

  services.logrotate.enable = lib.mkDefault true;
  services.openssh = {
    enable = lib.mkDefault true;
    challengeResponseAuthentication = lib.mkDefault false;
  };
  services.zfs.autoScrub.enable = lib.mkDefault true;

  services.opensmtpd= {
    enable = lib.mkDefault true;
    serverConfiguration = lib.mkDefault (
      let
        aliases = pkgs.writeText "aliases.conf" ''
          postmaster: root
          abuse: root
          hostmaster: root
        '';
      in ''
        listen on localhost

        table aliases file:${aliases}

        action "local" mbox alias <aliases>
        action "relay" relay

        match for local action "local"
        match from local for any action "relay"
      ''
    );
  };

  vpsadminos.nix = lib.mkDefault true;

  nix.daemon.enable = lib.mkDefault true;

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  boot.supportedFilesystems = [ "nfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];

  environment.systemPackages = with pkgs; [
    glibc
    iotop
    ipset
    less
    manpages
    ncurses
    openssh
    osctl
    osctl-image
    osctl-repo
    osup
    ruby
    screen
    strace
    sysstat
    vim
  ];

  environment.shellAliases = {
    ll = "ls -l";
    vim = "vi";
  };

  i18n = {
    defaultLocale = "en_US.UTF-8";
    supportedLocales = [ "en_US.UTF-8/UTF-8" ];
  };

  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = true;

    # TCP BBR congestion control
    "net.core.default_qdisc" = lib.mkDefault "fq";
    "net.ipv4.tcp_congestion_control" = lib.mkDefault "bbr";

    # Enable netfilter logs in all containers
    "net.netfilter.nf_log_all_netns" = lib.mkDefault true;
  };

  security.apparmor.enable = true;

  virtualisation = {
    lxc = {
      enable = true;
      lxcfs.enable = true;
    };
  };

  security.wrappers = {
    lxc-user-nic.source = "${pkgs.lxc}/libexec/lxc/lxc-user-nic";
  };

  environment.etc = {
    "nsswitch.conf".text = ''
      hosts:     files  dns   myhostname mymachines
      networks:  files dns
    '';
    "cgconfig.conf".text = ''
      mount {
        cpuset = /sys/fs/cgroup/cpuset;
        cpu = /sys/fs/cgroup/cpu,cpuacct;
        cpuacct = /sys/fs/cgroup/cpu,cpuacct;
        blkio = /sys/fs/cgroup/blkio;
        memory = /sys/fs/cgroup/memory;
        devices = /sys/fs/cgroup/devices;
        freezer = /sys/fs/cgroup/freezer;
        net_cls = /sys/fs/cgroup/net_cls,net_prio;
        net_prio = /sys/fs/cgroup/net_cls,net_prio;
        pids = /sys/fs/cgroup/pids;
        perf_event = /sys/fs/cgroup/perf_event;
        rdma = /sys/fs/cgroup/rdma;
        hugetlb = /sys/fs/cgroup/hugetlb;
        cglimit = /sys/fs/cgroup/cglimit;
        "name=systemd" = /sys/fs/cgroup/systemd;
      }
      group . {
        memory {
          memory.use_hierarchy = 1;
        }
      }
    '';
    "lxc/common.conf.d/00-lxcfs.conf".source = "${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf";
    # needed for osctl to access distro specific configs
    "lxc/config".source = "${pkgs.lxc}/share/lxc/config";

     # /etc/services: TCP/UDP port assignments.
    "services".source = pkgs.iana-etc + "/etc/services";
    # /etc/protocols: IP protocol numbers.
    "protocols".source  = pkgs.iana-etc + "/etc/protocols";
    # /etc/rpc: RPC program numbers.
    "rpc".source = pkgs.glibc.out + "/etc/rpc";
  };

  users.extraUsers.osctl-ct-receive = {
    uid = 499;
    description = "User for container send/receive";
    home = "/run/osctl/send-receive";
    shell = pkgs.bashInteractive;
  };

  users.extraUsers.repository = {
    uid = 498;
    description = "User for remote repository access/cache";
    home = "/run/osctl/repository";
  };

  programs.ssh.package = pkgs.openssh;
  programs.htop.enable = true;
}
