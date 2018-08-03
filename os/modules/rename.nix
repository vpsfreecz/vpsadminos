# Lightweight version of <nixpkgs/nixos/modules/rename.nix>
{ lib, pkgs, ... }:

with lib;

{
  imports = [
    # Users
    (mkAliasOptionModule [ "users" "extraUsers" ] [ "users" "users" ])
    (mkAliasOptionModule [ "users" "extraGroups" ] [ "users" "groups" ])

    # Networking
    (mkAliasOptionModule [ "networking" "useDHCP" ] [ "networking" "dhcp" ])
  ];
}
