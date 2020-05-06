{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
    chrony_config = pkgs.writeText "chrony_config" ''
    ${concatMapStringsSep "\n" (server: "server " + server) config.networking.timeServers}
    initstepslew 1000
    pidfile /run/chronyd.pid
  '';
in
{
  ###### interface

  options = {
    networking = {
      chronyd = mkOption {
        type = types.bool;
        description = "use Chrony daemon for network time synchronization";
        default = true;
      };

      timeServers = mkOption {
        default = [
          "0.nixos.pool.ntp.org"
          "1.nixos.pool.ntp.org"
          "2.nixos.pool.ntp.org"
          "3.nixos.pool.ntp.org"
        ];
        description = ''
          The set of NTP servers from which to synchronise.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.networking.chronyd) {
      runit.services.chronyd.run = ''
        exec ${pkgs.chrony}/bin/chronyd -n -m -u chrony -f ${chrony_config}
      '';
      environment.systemPackages = [ pkgs.chrony ];
      users.groups.chrony = { gid = config.ids.gids.chrony; };

      users.users.chrony = {
        uid = config.ids.uids.chrony;
        group = "chrony";
        description = "chrony daemon user";
        home = "/var/lib/chrony";
      };
    })
  ];
}
