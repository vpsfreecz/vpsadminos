{
  lib,
  pkgs,
  nixpkgsNode,
  stableNixpkgsNode,
  unstableNixpkgsNode,
  vpsadminosGithubRev ? null,
  includeImpermanence ? false,
  impermanenceNode,
  impermanenceNixpkgsNode,
  homeManagerNode,
}:
if vpsadminosGithubRev == null then
  null
else
  let
    rootInputs =
      lib.optionalAttrs includeImpermanence {
        impermanence = "impermanence";
      }
      // {
        nixpkgs = "nixpkgs";
        vpsadminos = "vpsadminos";
      };
  in
  pkgs.writeText "flake.lock" (
    builtins.toJSON {
      version = 7;
      root = "root";
      nodes = {
        root = {
          inputs = rootInputs;
        };
        nixpkgs = {
          inherit (nixpkgsNode) locked original;
        };
        vpsadminos-nixpkgs = {
          inherit (stableNixpkgsNode) locked original;
        };
        vpsadminos-nixpkgs-unstable = {
          inherit (unstableNixpkgsNode) locked original;
        };
        impermanence-nixpkgs = {
          inherit (impermanenceNixpkgsNode) locked original;
        };
        impermanence = {
          locked = impermanenceNode.locked;
          original = impermanenceNode.original;
          inputs = {
            home-manager = "home-manager";
            nixpkgs = "impermanence-nixpkgs";
          };
        };
        home-manager = {
          inherit (homeManagerNode) locked original;
          inputs = homeManagerNode.inputs;
        };
        vpsadminos = {
          inputs = {
            impermanence = "impermanence";
            nixpkgs = "vpsadminos-nixpkgs";
            nixpkgsUnstable = "vpsadminos-nixpkgs-unstable";
          };
          locked = {
            owner = "vpsfreecz";
            repo = "vpsadminos";
            rev = vpsadminosGithubRev;
            type = "github";
          };
          original = {
            owner = "vpsfreecz";
            repo = "vpsadminos";
            type = "github";
          };
        };
      };
    }
  )
