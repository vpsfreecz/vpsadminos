{
  lib,
  pkgs,
  config,
  ...
}:

with lib;

let
  kernelModules = lib.concatStringsSep " " config.boot.initrd.kernelModules;
  postBootCommands = pkgs.writeText "local-cmds" ''
    ${config.boot.postBootCommands}
  '';
in
{
  options = {
    boot = {
      postBootCommands = mkOption {
        default = "";
        example = "rm -f /var/log/messages";
        type = types.lines;
        description = ''
          Shell commands to be executed just before runit is started.
        '';
      };

      readOnlyNixStore = mkOption {
        type = types.bool;
        default = false;
        description = lib.mdDoc ''
          Deprecated. Prefer {option}`boot.nixStoreMountOpts`.

          If set, vpsAdminOS will enforce the immutability of the Nix store
          by making {file}`/nix/store` a read-only bind mount. Nix will
          automatically make the store writable when needed.
        '';
      };

      nixStoreMountOpts = mkOption {
        type = types.listOf types.nonEmptyStr;
        default =
          if config.boot.readOnlyNixStore then
            [
              "ro"
              "nodev"
              "nosuid"
            ]
          else
            [
              "nodev"
              "nosuid"
            ];
        defaultText = literalExpression ''
          if boot.readOnlyNixStore
          then [ "ro" "nodev" "nosuid" ]
          else [ "nodev" "nosuid" ]
        '';
        description = lib.mdDoc ''
          Defines the mount options used on a bind mount for the {file}`/nix/store`.
          This affects the whole system. The Nix daemon will remount the store
          as needed.

          `ro` enforces immutability of the Nix store.
          The store daemon should already not put device mappers or suid binaries in the store,
          meaning `nosuid` and `nodev` enforce what should already be the case.
        '';
      };

      procHidePid = mkOption {
        type = types.bool;
        default = false;
        description = "mount proc with hidepid=2";
      };
    };
  };
  config = {
    system.build.bootStage2 = pkgs.replaceVarsWith {
      src = ./stage-2-init.sh;
      isExecutable = true;
      replacements = {
        shell = "${pkgs.bash}/bin/bash";
        systemConfig = null; # replaced in ../activation/top-level.nix
        path = config.system.path;
        inherit (config.networking) hostName;
        inherit (config.boot) procHidePid;
        nixStoreMountOpts = concatStringsSep " " (map escapeShellArg config.boot.nixStoreMountOpts);
        inherit postBootCommands;
        writeBootUtmp = pkgs.write-boot-utmp;
        parentWrapperDir = dirOf config.security.wrapperDir;
        wrapperDirSize = config.security.wrapperDirSize;
      };
    };

    boot.readOnlyNixStore = mkIf (!config.boot.isLiveSystem) (mkDefault true);
  };
}
