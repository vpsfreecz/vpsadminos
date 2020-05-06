# Lightweight version of <nixpkgs/nixos/modules/rename.nix>
{ lib, pkgs, ... }:

with lib;

{
  imports = [
    # Networking
    (mkAliasOptionModule [ "networking" "useDHCP" ] [ "networking" "dhcp" ])
  ];
}
