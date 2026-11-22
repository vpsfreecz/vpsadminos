{ vpsadminos }:
let
  historical = import ../../os/lib/nixos-container/stable/historical-nixpkgs.nix;
in
{
  "24.11" =
    builtins.getFlake "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674?narHash=sha256-/bVBlRpECLVzjV19t5KMdMFWSwKLtb5RyXdjz3LJT+g=";
  "25.11" = historical."25.11".input;
  "26.05" = historical."26.05".input;
  "26.11" = vpsadminos.inputs.nixpkgs;
  unstable = vpsadminos.inputs.nixpkgsUnstable;
}
