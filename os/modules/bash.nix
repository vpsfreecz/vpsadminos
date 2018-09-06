{ config, lib, pkgs, ... }:
with lib;
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
      cfg = config.programs.bash.root;

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

        [ ! -f "${cfg.historyFile}" ] && touch "${cfg.historyFile}"
        chmod 0600 "${cfg.historyFile}"

        ${shoptsStr}
      '';

    in {
      programs.bash.interactiveShellInit = ''
        [ "$UID" == "0" ] && . ${bashrc}
      '';
    };
}
