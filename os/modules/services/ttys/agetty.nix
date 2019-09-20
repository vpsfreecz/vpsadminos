{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.tty;

  gettyAutoLogin = if cfg.autologin.enable then "--autologin ${cfg.autologin.user}" else "";
  gettyCmd = extraArgs: "${pkgs.utillinux}/bin/setsid ${pkgs.utillinux}/sbin/agetty ${gettyAutoLogin} --login-program ${pkgs.shadow}/bin/login ${extraArgs}";

  mkGetty = extraArgs: termtype: tty: lib.nameValuePair "getty-${tty}"
    {
      run = ''
        ${gettyCmd "${extraArgs} --keep-baud ${tty} 115200,38400,9600 ${termtype}"}
      '';

      runlevels = [ "single" "rescue" "default" ];
    };

  tty1 = mkGetty "--noclear" "linux" "tty1";
  mkTTY = mkGetty "" "linux";
  mkSTTY = mkGetty "" "vt100";
in
{
  ###### interface
  options = {
    tty = {
      spawnStandard = mkOption {
        type = types.ints.between 0 10;
        description = "Number of TTYs spawned, set to 0 to disable";
        default = 4;
      };

      spawnSerial = mkOption {
        type = types.ints.between 0 10;
        description = "Number of serial TTYs (STTYs) spawned (for /dev/ttyS0)";
        default = 1;
      };

      autologin = {
        enable = mkEnableOption "Enable autologin on ttys";
        user = mkOption {
         type = types.str;
         description = "Autologin user";
         default = "root";
        };
      };
    };
  };

  ###### implementation
  config = {
    runit.services = lib.listToAttrs (
      lib.optional (cfg.spawnStandard != 0) tty1
      ++ map mkTTY (map (x: "tty" + toString x) (lib.range 2 cfg.spawnStandard))  # [ "tty2", "tty3" ... ]
      ++ map mkSTTY (map (x: "ttyS" + toString x) (lib.range 0 cfg.spawnSerial)) # [ "ttyS0", .. ]
      );
  };
}
