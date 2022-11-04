{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.osctld;

  path = with pkgs; [
    apparmor-parser
    coreutils
    iproute
    glibc.bin
    gzip
    lxc
    nettools
    gnutar
    openssh
    runit
    shadow
    utillinux
    config.boot.zfsUserPackage
  ];

  pathJoined = concatMapStringsSep ":" (s: "${s}/bin") path;

  apparmorPaths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;

  settingsFormat = pkgs.formats.json { };

  configurationJson = settingsFormat.generate "osctld-config.json" cfg.settings;
in
{
  ###### interface

  options = {
    osctld = {
      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
        };
        default = {};
        description = ''
          osctld configuration options
        '';
      };
    };
  };

  ###### implementation

  config = {
    osctld.settings = {
      apparmor_paths = map (s: "${s}/etc/apparmor.d") apparmorPaths;

      ctstartmenu = "${pkgs.ctstartmenu}/bin/ctstartmenu";

      lxcfs = "${pkgs.lxcfs}/bin/lxcfs";
    };

    runit.services.osctld = {
      run = ''
        export PATH="${config.security.wrapperDir}:${pathJoined}"

        ${optionalString config.system.boot.restrict-proc-sysfs.enable ''
        waitForService restrict-proc-sysfs
        ''}

        waitForNetworkOnline 60

        waitForService live-patches 120

        ${optionalString config.networking.chronyd ''
        waitForService set-clock 30
        ''}

        exec 2>&1
        exec ${pkgs.osctld}/bin/osctld \
          --config ${configurationJson} \
          --log syslog \
          --log-facility local2
      '';
      killMode = "process";
    };
  };
}
