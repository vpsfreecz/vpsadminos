{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.services.build-vpsadminos-container-image-repository;

  shared = import ./shared.nix { inherit config pkgs lib; };
in {
  imports = [
    ./options.nix
  ];

  config = {
    environment.systemPackages = shared.createSystemPackages cfg;
  };
}
