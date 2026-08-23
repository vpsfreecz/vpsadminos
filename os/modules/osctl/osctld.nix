{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with utils;
with lib;

let
  cfg = config.osctld;
  rubyCrashReportTemplate = config.system.vpsadminos.rubyCrashReportTemplate;

  apparmorPaths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;

  settingsFormat = pkgs.formats.json { };

  configurationJson = settingsFormat.generate "osctld-config.json" cfg.settings;
in
{
  ###### interface

  options = {
    osctld = {
      waitForNetworkOnline = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Wait for the network to come online before starting osctld.
        '';
      };

      waitForSetClock = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Wait for the set-clock service before starting osctld.
        '';
      };

      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
        };
        default = { };
        description = ''
          osctld configuration options
        '';
      };
    };
  };

  ###### implementation

  config = {
    osctld.settings = {
      apparmor_paths = optionals config.security.apparmor.enable (
        map (s: "${s}/etc/apparmor.d") apparmorPaths
      );

      ct_wrapper = "${pkgs.ctptywrapper}/bin/osctld-ct-wrapper";
      ctstartmenu = "${pkgs.ctstartmenu}/bin/ctstartmenu";

      restart = {
        drain_timeout = mkDefault 300;
        cleanup_timeout = mkDefault 60;
        recovery_timeout = mkDefault 300;
        hook_timeout = mkDefault 30;
      };
    };

    # Reserve a private route protocol name for host routes managed by osctld.
    # iproute2 uses this mapping both when parsing commands and in JSON output.
    environment.etc."iproute2/rt_protos.d/osctld.conf".text = ''
      230 osctld
    '';

    runit.services.osctld = {
      path = with pkgs; [
        config.security.wrapperDir
        apparmor-parser
        coreutils
        findutils
        iproute2
        getent
        glibc.bin
        gzip
        lxc
        mbuffer
        nettools
        gnutar
        openssh
        runit
        ruby_vpsadminos
        shadow
        util-linux
        devcgprog
        bpftools
        config.boot.zfsUserPackage
      ];

      environment = {
        LANG = "en_US.UTF-8";
        LOCALE_ARCHIVE = "/run/current-system/sw/lib/locale/locale-archive";
      };

      run = ''
        ${optionalString config.system.boot.restrict-proc-sysfs.enable ''
          waitForService restrict-proc-sysfs
        ''}

        ${optionalString (config.boot.supportedFilesystems.zfs or false) ''
          waitForService zfs-module-parameters
        ''}

        ${optionalString cfg.waitForNetworkOnline ''
          waitForNetworkOnline 60
        ''}

        waitForService live-patches 120

        ${optionalString (config.networking.chronyd && cfg.waitForSetClock) ''
          waitForService set-clock 30
        ''}

        ${optionalString (!isNull rubyCrashReportTemplate) ''
          export RUBY_CRASH_REPORT=${escapeShellArg rubyCrashReportTemplate}
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
