let
  system = builtins.currentSystem;
  vpsadminos = builtins.getFlake (toString ../.);
  evaluated = import (vpsadminos.nixpkgsPath + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      ../os/modules/services/misc/build-vpsadminos-container-image-repository/nixos.nix
      {
        system.stateVersion = "26.05";
      }
    ];
  };
in
evaluated.pkgs.osvm.drvPath
