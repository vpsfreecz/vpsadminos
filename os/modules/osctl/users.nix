{ config, lib, pkgs, utils, ... }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  idRangeName = name: if name == null then "default" else name;

  isBlockIndexDeclared = pool: idRange:
    let
      range = idRangeName idRange.name;
      cfg = config.osctl.pools.${pool}.idRanges;
      rangeExists = hasAttr range cfg;
      indexExists = any (alloc: alloc.index == idRange.blockIndex) cfg.${range}.table;
    in idRange.blockIndex != null && rangeExists && indexExists;

  mapOpts = type: idMap: map (v: "--map-${type} ${v}") idMap;

  ugidMapOpts = cfg:
    concatStringsSep " " ((mapOpts "uid" cfg.uidMap) ++ (mapOpts "gid" cfg.gidMap));

  createUsers = pool: users: concatStringsSep "\n\n" (mapAttrsToList (user: cfg: (
    let
      osctlPool = "${osctl} --pool ${pool}";

      hasRange = cfg.idRange.name != null;

      hasBlockIndex = cfg.idRange.blockIndex != null;

    in ''
      ### User ${pool}:${user}
      ugid=$(${osctlPool} user show -H -o ugid ${user} 2> /dev/null)
      hasUser=$?
      if [ "$hasUser" == "0" ] ; then
        echo "User ${pool}:${user} already exists"
      else
        ${optionalString hasRange "waitForOsctlEntity id-range ${pool}:${cfg.idRange.name}"}
        ${optionalString (isBlockIndexDeclared pool cfg.idRange) ''
        while true ; do
          type=$(${osctlPool} id-range table show -H -o type ${idRangeName cfg.idRange.name} ${toString cfg.idRange.blockIndex} 2> /dev/null)
          [ "$type" == "allocated" ] && break
          echo "Waiting for block allocation at" \
               "${idRangeName cfg.idRange.name}:#${toString cfg.idRange.blockIndex}"
          sleep 1
        done
        ''}

        echo "Creating user ${pool}:${user}"
        ${osctlPool} user new \
          ${optionalString (hasRange) "--id-range ${cfg.idRange.name}"} \
          ${optionalString hasBlockIndex "--id-range-block-index ${toString cfg.idRange.blockIndex}"} \
          ${ugidMapOpts cfg} \
          ${user}
        ${osctlPool} user set attr ${user} org.vpsadminos.osctl:declarative yes
      fi
    '')) users);
in
{
  type = {
    options = {
      uidMap = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "0:666000:65536" ];
        description = ''
          UID mapping for the user namespace, see man subuid(5).
        '';
      };

      gidMap = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "0:666000:65536" ];
        description = ''
          GID mapping for the user namespace, see man subgid(5).
        '';
      };

      idRange = {
        name = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Name of an ID range from the same pool that should be used to allocate
            UID/GID IDs.
          '';
        };

        blockIndex = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = ''
            Block index from the ID range that should be used to create UID/GID
            mapping.
          '';
        };
      };
    };
  };

  mkServices = pool: users: mkIf (users != {}) {
    "users-${pool}" = {
      run = ''
        waitForOsctld
        waitForOsctlEntity pool ${pool}
        ${createUsers pool users}
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
