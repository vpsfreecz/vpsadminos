{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  apparmor_paths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;
  apparmor_paths_joined = concatMapStringsSep ":" (s: "${s}/etc/apparmor.d") apparmor_paths;
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
    runit.services.osctld.run = ''
      export PATH="$PATH:${pkgs.apparmor-parser}/bin"
      export OSCTLD_APPARMOR_PATHS="${apparmor_paths_joined}"

      exec 2>&1
      exec ${pkgs.osctld}/bin/osctld --log syslog --log-facility local2
    '';
  };
}
