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
    kbdInteractiveAuthentication = lib.mkDefault false;
  };
  services.zfs.autoScrub = lib.mkDefault {
    enable = true;
    startIntervals = [ "0 4 */14 * *" ];
  };

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

  nix = {
    daemon.enable = lib.mkDefault true;
    binaryCaches = [
      "https://cache.vpsadminos.org"
    ];
    binaryCachePublicKeys = [
      "cache.vpsadminos.org:wpIJlNZQIhS+0gFf1U3MC9sLZdLW3sh5qakOWGDoDrE="
    ];
  };

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  boot.supportedFilesystems = [ "nfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];

  environment.systemPackages = with pkgs; [
    acl
    glibc
    iotop
    ipset
    less
    man-pages
    ncurses
    openssh
    osctl
    osctl-image
    osctl-repo
    osup
    ruby
    screen
    scrubctl
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
    "fs.protected_hardlinks" = lib.mkDefault 1;
    "fs.protected_symlinks" = lib.mkDefault 1;

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
    lxc-user-nic = {
      source = "${pkgs.lxc}/libexec/lxc/lxc-user-nic";
      owner = "root";
      group = "root";
      setuid = true;
    };
  };

  environment.etc = {
    "nsswitch.conf".text = ''
      hosts:     files  dns   myhostname mymachines
      networks:  files dns
    '';
    "lxc/common.conf.d/00-lxcfs.conf".source = "${pkgs.lxcfs}/share/lxc/config/common.conf.d/00-lxcfs.conf";
    # needed for osctl to access distro specific configs
    "lxc/config".source = "${pkgs.lxc}/share/lxc/config";

    "mbuffer.rc".text = ''
      tcptimeout = 0
    '';

     # /etc/services: TCP/UDP port assignments.
    "services".source = pkgs.iana-etc + "/etc/services";
    # /etc/protocols: IP protocol numbers.
    "protocols".source  = pkgs.iana-etc + "/etc/protocols";
    # /etc/rpc: RPC program numbers.
    "rpc".source = pkgs.glibc.out + "/etc/rpc";
  };

  users = {
    users.osctl-ct-receive = {
      uid = 499;
      description = "User for container send/receive";
      home = "/run/osctl/send-receive";
      shell = pkgs.bashInteractive;
      group = "osctl-ct-receive";
    };

    groups.osctl-ct-receive = {};

    users.repository = {
      uid = 498;
      description = "User for remote repository access/cache";
      home = "/run/osctl/repository";
      group = "repository";
    };

    groups.repository = {};
  };

  programs.ssh.package = pkgs.openssh;
  programs.htop.enable = true;
}
