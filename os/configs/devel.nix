{ config, ... }:
{
  boot.qemu.sharedFileSystems = [
    { handle = "hostNixPath"; hostPath = "../.."; guestPath = "/mnt/nix-path"; }
    { handle = "hostOs"; hostPath = ".."; guestPath = "/mnt/vpsadminos" }
  ];

  nix.nixPath = [
    "nixpkgs=/mnt/nix-path/nixpkgs"
    "nixpkgs-overlays=/mnt/vpsadminos/os/overlays"
  ];
}
