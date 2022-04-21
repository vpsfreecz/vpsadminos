{ config, lib, pkgs, utils, shared, ... }:
with lib;

let
  boolToStr = x: if x then "true" else "false";

  osctl = "osctl";

  entities = [ "containers" "groups" "users" "repositories" "idRanges" ];

  sweepScript = pool: cfg:
    let
      osctlPool = "${osctl} --pool ${pool}";

      writeList = type: list:
        pkgs.writeText "gc-${pool}-${type}" (concatStringsSep "\n" list);

      definitions = listToAttrs (map (ent:
        nameValuePair ent (writeList ent (mapAttrsToList (k: v: k) cfg.${ent}))
      ) entities);

    in pkgs.writeScriptBin "gc-sweep-${pool}" ''
      #!${pkgs.bash}/bin/bash

      destroyUndeclared=n
      destroyImperative=n

      usage () {
        cat <<EOF
      Usage: gc-sweep-${pool} [--destroy-undeclared] [--destroy-imperative]

      Options:

        --destroy-undeclared      Destroy declarative containers that are not part
                                  of the configuration
        --destroy-imperative      Destroy all imperatively created containers

      EOF
      }

      for arg in "$@" ; do
        case "$arg" in
          --destroy-undeclared)
            destroyUndeclared=y
            ;;
          --destroy-imperative)
            destroyImperative=y
            ;;
          -h|--help)
            usage
            exit
            ;;
          *)
            echo "Unknown option '$arg'"
            echo
            usage
            exit 1
        esac
      done

      defined () {
        local list="$1"
        local value="$2"

        grep -w "$value" "$list" &> /dev/null || return 1
      }

      entryList="$(mktemp -t gc-entries.XXXXXX)"

      ### Repositories
      ${osctlPool} repository ls -H -o name,org.vpsadminos.osctl:declarative > "$entryList"

      if [ "$?" != "0" ] ; then
        echo "Unable to list repositories"
        rm -f "$entryList"
        exit 1
      fi

      cat "$entryList" | while read line ; do
        repo=($line)
        name="''${repo[0]}"
        declarative="''${repo[1]}"

        [ "$name" == "default" ] && continue
        defined "${definitions.repositories}" "$name" && continue

        if [ "$declarative" == "yes" ] ; then
          echo "Found leftover declarative repository ${pool}:$name"

          if [ "$destroyUndeclared" == "y" ] ; then
            echo "Removing repository ${pool}:$name"
            ${osctlPool} repo del "$name"
          fi

        else
          echo "Repository ${pool}:$name exists, but is not declarative"

          if [ "$destroyImperative" == "y" ] ; then
            echo "Removing repository ${pool}:$name"
            ${osctlPool} repository del "$name"
          fi
        fi
      done

      ### Containers
      ${osctlPool} ct ls -H -o id,state,org.vpsadminos.osctl:declarative > "$entryList"

      if [ "$?" != "0" ] ; then
        echo "Unable to list containers"
        rm -f "$entryList"
        exit 1
      fi

      cat "$entryList" | while read line ; do
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

          if [ "$destroyUndeclared" == "y" ] ; then
            echo "Removing container ${pool}:$ctid"
            ${osctlPool} ct del --force "$ctid"
            rm -f "/nix/var/nix/profiles/per-container/$ctid" \
                  "/nix/var/nix/gcroots/per-container/$ctid"
          fi

        else
          echo "Container ${pool}:$ctid exists, but is not declarative"

          if [ "$destroyImperative" == "y" ] ; then
            echo "Removing container ${pool}:$ctid"
            ${osctlPool} ct del --force "$ctid"
          fi
        fi
      done

      ### Groups
      ${osctlPool} group ls -H -o name,org.vpsadminos.osctl:declarative > "$entryList"

      if [ "$?" != "0" ] ; then
        echo "Unable to list groups"
        rm -f "$entryList"
        exit 1
      fi

      cat "$entryList" | sort -r -k 1,1 | while read line ; do
        grp=($line)
        name="''${grp[0]}"
        declarative="''${grp[1]}"

        ([ "$name" == "/" ] || [ "$name" == "/default" ]) && continue
        defined "${definitions.groups}" "$name" && continue

        if [ "$declarative" == "yes" ] ; then
          echo "Found leftover declarative group ${pool}:$name"

          if [ "$destroyUndeclared" == "y" ] ; then
            echo "Removing group ${pool}:$name"
            ${osctlPool} group del "$name"
          fi

        else
          echo "Group ${pool}:$name exists, but is not declarative"

          if [ "$destroyImperative" == "y" ] ; then
            echo "Removing group ${pool}:$name"
            ${osctlPool} group del "$name"
          fi
        fi
      done

      ### Users
      ${osctlPool} user ls -H -o name,org.vpsadminos.osctl:declarative > "$entryList"

      if [ "$?" != "0" ] ; then
        echo "Unable to list users"
        rm -f "$entryList"
        exit 1
      fi

      cat "$entryList" | while read line ; do
        user=($line)
        name="''${user[0]}"
        declarative="''${user[1]}"

        defined "${definitions.users}" "$name" && continue

        if [ "$declarative" == "yes" ] ; then
          echo "Found leftover declarative user ${pool}:$name"

          if [ "$destroyUndeclared" == "y" ] ; then
            echo "Removing user ${pool}:$name"
            ${osctlPool} user del "$name"
          fi

        else
          echo "User ${pool}:$name exists, but is not declarative"

          if [ "$destroyImperative" == "y" ] ; then
            echo "Removing user ${pool}:$name"
            ${osctlPool} user del "$name"
          fi
        fi
      done

      ### ID ranges
      ${osctlPool} id-range ls -H -o name,org.vpsadminos.osctl:declarative > "$entryList"

      if [ "$?" != "0" ] ; then
        echo "Unable to list ID ranges"
        rm -f "$entryList"
        exit 1
      fi

      cat "$entryList" | while read line ; do
        range=($line)
        name="''${range[0]}"
        declarative="''${range[1]}"

        [ "$name" == "default" ] && continue
        defined "${definitions.idRanges}" "$name" && continue

        if [ "$declarative" == "yes" ] ; then
          echo "Found leftover declarative ID range ${pool}:$name"

          if [ "$destroyUndeclared" == "y" ] ; then
            echo "Removing ID range ${pool}:$name"
            ${osctlPool} id-range del "$name"
          fi

        elif [ "$name" == "default" ] ; then
          echo "Ignoring the default ID range"

        else
          echo "ID range ${pool}:$name exists, but is not declarative"

          if [ "$destroyImperative" == "y" ] ; then
            echo "Removing ID range ${pool}:$name"
            ${osctlPool} id-range del "$name"
          fi
        fi
      done

      rm -f "$entryList"
    '';

in
{
  mkService = pool: cfg: mkIf (cfg.destroyMethod == "auto") {
    "gc-${pool}" = {
      run = ''
        ${osctl} pool show ${pool} &> /dev/null
        hasPool=$?
        if [ "$hasPool" != "0" ] ; then
          echo "Waiting for pool ${pool}"
          exit 1
        fi

        ${sweepScript pool cfg}/bin/gc-sweep-${pool} \
          ${optionalString cfg.destroyUndeclared "--destroy-undeclared"} \
          ${optionalString cfg.pure "--destroy-imperative"} \
          || exit 1
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };

  systemPackages = pool: cfg: [ (sweepScript pool cfg) ];
}
