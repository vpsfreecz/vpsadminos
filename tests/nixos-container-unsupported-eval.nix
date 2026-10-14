release:
let
  vpsadminos = builtins.getFlake (toString ../.);
  lib = vpsadminos.inputs.nixpkgs.lib;
in
builtins.deepSeq
  (vpsadminos.nixosModules.containerStable {
    lib = lib // {
      trivial = lib.trivial // {
        inherit release;
      };
    };
  }).imports
  true
