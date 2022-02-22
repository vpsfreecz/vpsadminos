{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
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
  apparmorPathsJoined = concatMapStringsSep ":" (s: "${s}/etc/apparmor.d") apparmorPaths;
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
    runit.services.osctld = {
      run = ''
        export PATH="${config.security.wrapperDir}:${pathJoined}"
        export OSCTLD_APPARMOR_PATHS="${apparmorPathsJoined}"
        export OSCTLD_CT_START_MENU="${pkgs.ctstartmenu}/bin/ctstartmenu"

        ${optionalString config.system.boot.restrict-proc-sysfs.enable ''
        waitForService restrict-proc-sysfs
        ''}

        waitForNetworkOnline 60

        waitForService live-patches 120

        ${optionalString config.networking.chronyd ''
        waitForService set-clock 15
        ''}

        exec 2>&1
        exec ${pkgs.osctld}/bin/osctld --log syslog --log-facility local2
      '';
      killMode = "process";
    };
  };
}
