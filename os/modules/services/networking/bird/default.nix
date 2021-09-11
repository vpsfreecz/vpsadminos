{ config, lib, pkgs, ... }@args:
let
  generic = variant: import ./generic.nix variant args;
in {
  imports = [
    (generic "bird")
    (generic "bird6")
  ];
}
