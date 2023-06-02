{ lib, pkgs, config, ... }:

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
        default = true;
        description = lib.mdDoc ''
          If set, NixOS will enforce the immutability of the Nix store
          by making {file}`/nix/store` a read-only bind
          mount.  Nix will automatically make the store writable when
          needed.
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
    system.build.bootStage2 = pkgs.substituteAll {
      src = ./stage-2-init.sh;
      isExecutable = true;
      path = config.system.path;
      inherit (config.networking) hostName;
      inherit (config.boot) procHidePid readOnlyNixStore;
      inherit postBootCommands;
    };
  };
}
