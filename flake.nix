{
  description = "vpsAdminOS flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixpkgsUnstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.impermanence.url = "github:nix-community/impermanence";
  inputs.netlinkrb = {
    url = "github:vpsfreecz/netlinkrb";
    flake = false;
  };
  inputs.ruby-lxc = {
    url = "github:vpsfreecz/ruby-lxc/2026-06-03-nixos-26-05-port";
    flake = false;
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgsUnstable,
      ...
    }:
    import ./nix/flake/outputs.nix {
      inherit
        inputs
        nixpkgs
        nixpkgsUnstable
        self
        ;
      root = ./.;
    };
}
