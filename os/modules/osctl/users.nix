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
      else
        echo "Creating user ${pool}:${user}"
        ${osctlPool} user new ${ugidMapOpts cfg} ${user}
        ${osctlPool} user set attr ${user} org.vpsadminos.osctl:declarative yes
      fi
    '')) users);
in
{
  type = {
    options = {
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
