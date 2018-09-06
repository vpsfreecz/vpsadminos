{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.programs.bash.root;

  inotifywait = "${pkgs.inotify-tools}/bin/inotifywait";
  rsync = "${pkgs.rsync}/bin/rsync";

  poolService = pool: {
    run = ''
      HOME="$(getent passwd root | cut -d: -f6)"
      child=

      stopit () {
        [ "$child" != "" ] && kill $child
        exit 1
      }

      trap "stopit" SIGINT SIGTERM

      histfile="$(zfs get -Hpo value mountpoint ${pool})/.bash_history"
      [ "$?" != "0" ] && exit 1

      mounted="$(zfs get -Hpo value mounted ${pool})"
      ([ "$?" != "0" ] || [ "$mounted" != "yes" ]) && exit 1

      if [ ! -e "${cfg.historyFile}" ] && [ -s "$histfile" ] ; then
        echo "Restoring ${cfg.historyFile} from $histfile"
        ${rsync} "$histfile" "${cfg.historyFile}"
      fi

      [ ! -e "$histfile" ] && touch "$histfile"
      chmod 0600 "$histfile"

      if [ ! -e "${cfg.historyFile}" ] ; then
        echo "Waiting for ${cfg.historyFile} to be created"
        while true ; do
          [ -e "${cfg.historyFile}" ] && break

          ${inotifywait} -qq -e create "$(dirname ${cfg.historyFile})" &
          child=$!
          wait $child

          [ -e "${cfg.historyFile}" ] && break
          sleep 1
        done
      fi

      echo "Monitoring ${cfg.historyFile}"
      while true ; do
        ${inotifywait} -qq -e modify "${cfg.historyFile}" &
        child=$!
        wait $child

        case "$?" in
          0) ;;
          1) sleep 1 ; continue ;; # different event
          *) exit 1             ;; # killed by another signal
        esac

        echo "Synchronizing ${cfg.historyFile} to $histfile"
        ${rsync} "${cfg.historyFile}" "$histfile"
        sleep 1
      done
    '';

    log.enable = true;
    log.sendTo = "127.0.0.1";
  };

in

{
  options = {
    programs.bash.root = {
      historySize = mkOption {
        type = types.int;
        default = 10000;
        description = "Number of history lines to keep in memory.";
      };

      historyFile = mkOption {
        type = types.str;
        default = "$HOME/.bash_history";
        description = "Location of the bash history file.";
      };

      historyFileSize = mkOption {
        type = types.int;
        default = 100000;
        description = "Number of history lines to keep on file.";
      };

      historyControl = mkOption {
        type = types.listOf (types.enum [
          "erasedups"
          "ignoredups"
          "ignorespace"
        ]);
        default = [];
        description = "Controlling how commands are saved on the history list.";
      };

      historyIgnore = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "ls" "cd" "exit" ];
        description = "List of commands that should not be saved to the history list.";
      };

      historyPools = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "tank" ];
        description = ''
          Names of ZFS pools where <option>programs.bash.root.historyFile</option>
          is mirrored.

          If the root file system is not persistent, shell history is lost
          between reboots. It's not recommented to set
          <option>programs.bash.root.historyFile</option> to a location on
          ZFS pools, because in case of its failure interactive shell sessions
          would hang while trying to load the history file.

          It is better to mirror the history file while possible, but its
          inaccessibility will not prevent bash from working. The history file
          is restored from the persistent storage during boot.
        '';
      };

      shellOptions = mkOption {
        type = types.listOf types.str;
        default = [
          # Append to history file rather than replacing it.
          "histappend"

          # check the window size after each command and, if
          # necessary, update the values of LINES and COLUMNS.
          "checkwinsize"

          # Extended globbing.
          "extglob"
          "globstar"

          # Warn if closing shell with running jobs.
          "checkjobs"
        ];
        description = "Shell options to set.";
      };
    };
  };

  config =
    let
      shoptsStr = concatStringsSep "\n" (
        map (v: "shopt -s ${v}") cfg.shellOptions
      );

      historyControlStr =
        concatStringsSep "\n" (mapAttrsToList (n: v: "${n}=${v}") (
          {
            HISTFILE = "\"${cfg.historyFile}\"";
            HISTFILESIZE = toString cfg.historyFileSize;
            HISTSIZE = toString cfg.historySize;
          }
          // optionalAttrs (cfg.historyControl != []) {
            HISTCONTROL = concatStringsSep ":" cfg.historyControl;
          }
          // optionalAttrs (cfg.historyIgnore != []) {
            HISTIGNORE = concatStringsSep ":" cfg.historyIgnore;
          }
        ));

      bashrc = pkgs.writeText "root-bashrc" ''
        ${historyControlStr}
        ${shoptsStr}
      '';

    in {
      programs.bash.interactiveShellInit = ''
        [ "$UID" == "0" ] && . ${bashrc}
      '';

      runit.services = listToAttrs (map (pool:
        nameValuePair "histfile-${pool}" (poolService pool)
      ) cfg.historyPools);
    };
}
