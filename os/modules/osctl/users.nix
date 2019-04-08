{ config, lib, pkgs, utils, ... }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  mapOpts = type: idMap: map (v: "--map-${type} ${v}") idMap;

  ugidMapOpts = cfg:
    concatStringsSep " " ((mapOpts "uid" cfg.uidMap) ++ (mapOpts "gid" cfg.gidMap));

  createUsers = pool: users: concatStringsSep "\n\n" (mapAttrsToList (user: cfg: (
    let
      osctlPool = "${osctl} --pool ${pool}";

    in ''
      ### User ${pool}:${user}
      ugid=$(${osctlPool} user show -H -o ugid ${user} 2> /dev/null)
      hasUser=$?
      if [ "$hasUser" == "0" ] ; then
        echo "User ${pool}:${user} already exists"

        ${optionalString (cfg.ugid != null) ''
        if [ "${toString cfg.ugid}" != "$ugid" ] ; then
          echo "Warning: ugid has been changed in configuration, but" \
               "an existing user cannot be manipulated"
        fi
        ''}

      else
        echo "Creating user ${pool}:${user}"
        ${osctlPool} user new \
          ${optionalString (cfg.ugid != null) "--ugid ${toString cfg.ugid}"} \
          ${ugidMapOpts cfg} \
          ${user}
        ${osctlPool} user set attr ${user} org.vpsadminos.osctl:declarative yes
      fi
    '')) users);
in
{
  type = {
    options = {
      ugid = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 5000;
        description = "UID/GID of the system user that is used to run containers";
      };

      uidMap = mkOption {
        type = types.listOf types.str;
        example = [ "0:666000:65536" ];
        description = ''
          UID mapping for the user namespace, see man subuid(5).
        '';
      };

      gidMap = mkOption {
        type = types.listOf types.str;
        example = [ "0:666000:65536" ];
        description = ''
          GID mapping for the user namespace, see man subgid(5).
        '';
      };
    };
  };

  mkServices = pool: users: mkIf (users != {}) {
    "users-${pool}" = {
      run = ''
        waitForOsctld
        waitForOsctlEntity pool ${pool}
        ${createUsers pool users}
        sv once users-${pool}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
