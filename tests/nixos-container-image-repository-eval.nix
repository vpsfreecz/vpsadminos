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
  inherit (evaluated.pkgs) lib;
  repository = import ../os/configs/image-repository.nix {
    inherit (evaluated) config pkgs;
    inherit lib;
  };
  images = repository.services.osctl.image-repository.vpsadminos.images.nixos;
  tags = name: images.${name}.tags or [ ];
in
assert lib.all
  (
    suffix:
    tags ("25.11" + suffix) == [ ]
    &&
      tags ("26.05" + suffix) == [
        "latest"
        "stable"
      ]
    && tags ("26.11" + suffix) == [ ]
    && tags ("unstable" + suffix) == [ "unstable" ]
  )
  [
    ""
    "-impermanence"
  ];
evaluated.pkgs.osvm.drvPath
