{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.swraid;
  mdadmConfFile = pkgs.writeText "mdadm.conf" cfg.mdadmConf;
in
{
  options.boot.swraid = {
    enable = lib.mkEnableOption "mdadm support in initrd";

    mdadmConf = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Contents of {file}`/etc/mdadm.conf`.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.mdadm ];

    environment.etc."mdadm.conf".text = lib.mkAfter cfg.mdadmConf;

    boot.initrd = {
      availableKernelModules = [
        "md_mod"
        "raid0"
        "raid1"
        "raid10"
        "raid456"
      ];

      extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.mdadm}/sbin/mdadm
      '';

      extraUtilsCommandsTest = ''
        $out/bin/mdadm --version > /dev/null
      '';

      preLVMCommands = lib.mkBefore (
        lib.optionalString (cfg.mdadmConf != "") ''
          cp ${mdadmConfFile} /etc/mdadm.conf
        ''
      );
    };
  };
}
