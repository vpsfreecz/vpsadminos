{ config, lib, pkgs, utils, shared, ... }:
with lib;
{
  mkService = pool: cfg:
    let
      boolToStr = x: if x then "true" else "false";

      osctl = "${pkgs.osctl}/bin/osctl";
      osctlPool = "${osctl} --pool ${pool}";

      writeList = type: list:
        pkgs.writeText "gc-${pool}-${type}" (concatStringsSep "\n" list);

      entities = [ "containers" "groups" "users" "repositories" ];

      definitions = listToAttrs (map (ent:
        nameValuePair ent (writeList ent (mapAttrsToList (k: v: k) cfg.${ent}))
      ) entities);
      
    in {
      "gc-${pool}" = {
        run = ''
          defined () {
            local list="$1"
            local value="$2"

            grep -w "$value" "$list" &> /dev/null || return 1
          }

          ### Repositories
          ${osctlPool} repository ls -H -o name,org.vpsadminos.osctl:declarative \
            | while read line ; do
            repo=($line)
            name="''${repo[0]}"
            declarative="''${repo[1]}"

            [ "$name" == "default" ] && continue
            defined "${definitions.repositories}" "$name" && continue

            if [ "$declarative" == "yes" ] ; then
              echo "Found leftover declarative repository ${pool}:$name"

              ${optionalString cfg.destroyUndeclared ''
                echo "Removing repository ${pool}:$name"
                ${osctlPool} repo del "$name"
              ''}

            else
              echo "Repository ${pool}:$name exists, but is not declarative"

              ${optionalString cfg.pure ''
                echo "Removing repository ${pool}:$name"
                ${osctlPool} repository del "$name"
              ''}
            fi
          done

          ### Containers
          ${osctlPool} ct ls -H -o id,state,org.vpsadminos.osctl:declarative \
            | while read line ; do
            ct=($line)
            ctid="''${ct[0]}"
            state="''${ct[1]}"
            declarative="''${ct[2]}"

            defined "${definitions.containers}" "$ctid" && continue

            if [ "$declarative" == "yes" ] ; then
              if [ "$state" != "stopped" ] ; then
                echo "Stopping removed declarative container ${pool}:$ctid"
                ${osctlPool} ct stop "$ctid"
              else
                echo "Found leftover declarative container ${pool}:$ctid"
              fi

              ${optionalString cfg.destroyUndeclared ''
                echo "Removing container ${pool}:$ctid"
                ${osctlPool} ct del --force "$ctid"
                rm -f "/nix/var/nix/profiles/per-container/$ctid" \
                      "/nix/var/nix/gcroots/per-container/$ctid"
              ''}

            else
              echo "Container ${pool}:$ctid exists, but is not declarative"

              ${optionalString cfg.pure ''
                echo "Removing container ${pool}:$ctid"
                ${osctlPool} ct del --force "$ctid"
              ''}
            fi
          done

          ### Groups
          ${osctlPool} group ls -H -o name,org.vpsadminos.osctl:declarative \
            | sort -r -k 1,1 | while read line ; do
            grp=($line)
            name="''${grp[0]}"
            declarative="''${grp[1]}"

            ([ "$name" == "/" ] || [ "$name" == "/default" ]) && continue
            defined "${definitions.groups}" "$name" && continue

            if [ "$declarative" == "yes" ] ; then
              echo "Found leftover declarative group ${pool}:$name"

              ${optionalString cfg.destroyUndeclared ''
                echo "Removing group ${pool}:$name"
                ${osctlPool} group del "$name"
              ''}

            else
              echo "Group ${pool}:$name exists, but is not declarative"

              ${optionalString cfg.pure ''
                echo "Removing group ${pool}:$name"
                ${osctlPool} group del "$name"
              ''}
            fi
          done

          ### Users
          ${osctlPool} user ls -H -o name,org.vpsadminos.osctl:declarative \
            | while read line ; do
            user=($line)
            name="''${user[0]}"
            declarative="''${user[1]}"

            defined "${definitions.users}" "$name" && continue

            if [ "$declarative" == "yes" ] ; then
              echo "Found leftover declarative user ${pool}:$name"

              ${optionalString cfg.destroyUndeclared ''
                echo "Removing user ${pool}:$name"
                ${osctlPool} user del "$name"
              ''}

            else
              echo "User ${pool}:$name exists, but is not declarative"

              ${optionalString cfg.pure ''
                echo "Removing user ${pool}:$name"
                ${osctlPool} user del "$name"
              ''}
            fi
          done

          sv once gc-${pool}
        '';
        
        log.enable = true;
        log.sendTo = "127.0.0.1";
      };
    };
}
