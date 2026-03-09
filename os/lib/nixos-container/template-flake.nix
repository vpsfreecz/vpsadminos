{
  lib,
  pkgs,
  containerModule,
  nixpkgsNode,
  stableNixpkgsNode,
  unstableNixpkgsNode,
  impermanenceNode,
  impermanenceNixpkgsNode,
  homeManagerNode,
}:
let
  githubInputUrl =
    node:
    let
      base = "github:${node.original.owner}/${node.original.repo}";
    in
    if node.original ? ref then "${base}/${node.original.ref}" else base;

  vpsadminosInputUrl = "github:vpsfreecz/vpsadminos";
  nixpkgsInputUrl = githubInputUrl nixpkgsNode;

  vpsadminosInputs = ''
    vpsadminos.url = "${vpsadminosInputUrl}";
    vpsadminos.inputs.nixpkgs.url = "${githubInputUrl stableNixpkgsNode}";
    vpsadminos.inputs.nixpkgsUnstable.url = "${githubInputUrl unstableNixpkgsNode}";
    vpsadminos.inputs.impermanence.url = "${githubInputUrl impermanenceNode}";
    vpsadminos.inputs.impermanence.inputs.nixpkgs.url = "${githubInputUrl impermanenceNixpkgsNode}";
    vpsadminos.inputs.impermanence.inputs.home-manager.url = "${githubInputUrl homeManagerNode}";
  '';

  impermanenceInputs = ''
    impermanence.url = "${githubInputUrl impermanenceNode}";
    impermanence.inputs.nixpkgs.url = "${githubInputUrl impermanenceNixpkgsNode}";
    impermanence.inputs.home-manager.url = "${githubInputUrl homeManagerNode}";
  '';
in
pkgs.writeText "flake.nix" ''
  {
    description = "vpsAdminOS container";

    inputs = {
      ${vpsadminosInputs}
      nixpkgs.url = "${nixpkgsInputUrl}";
      ${impermanenceInputs}
    };

    outputs =
      inputs@{
        nixpkgs,
        vpsadminos,
        ...
      }:
      let
        system = "x86_64-linux";
      in
      {
        nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            vpsadminos.nixosModules.${containerModule}
            ./configuration.nix
          ];
          specialArgs = {
            inherit inputs;
          };
        };
      };
  }
''
