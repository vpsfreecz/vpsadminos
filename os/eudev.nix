{ config, lib, pkgs, utils, ... }:

with lib;
let
  hwdbBin = pkgs.runCommand "hwdb.bin"
    { preferLocalBuild = true;
      allowSubstitutes = false;
    }
    ''
      mkdir -p etc/udev/hwdb.d
      for i in ${pkgs.eudev}/var/lib/udev/hwdb.d/*; do
        ln -s $i etc/udev/hwdb.d/$(basename $i)
      done

      echo "Generating hwdb database..."
      # hwdb --update doesn't return error code even on errors!
      res="$(${pkgs.eudev}/bin/udevadm hwdb --update --root=$(pwd) 2>&1)"
      echo $res
      [ -z "$(echo "$res" | egrep '^Error')" ]
      mv etc/udev/hwdb.bin $out
    '';
  enableUdev = true;
in
{
  config = mkMerge [
    (mkIf enableUdev {
      environment.etc = {
        "udev/rules.d".source = "${pkgs.eudev}/var/lib/udev/rules.d";
        "udev/hwdb.bin".source = hwdbBin;
      };
    })
  ];
}

