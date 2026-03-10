{
  lib,
  pkgs,
  containerModule,
  nixpkgsNode,
  includeImpermanence ? false,
  impermanenceNode ? null,
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
  inputLines = [
    "    vpsadminos.url = \"${vpsadminosInputUrl}\";"
    ""
    "    nixpkgs.url = \"${nixpkgsInputUrl}\";"
  ]
  ++ lib.optional includeImpermanence "    impermanence.url = \"${githubInputUrl impermanenceNode}\";";
  moduleLines = [
    "          vpsadminos.nixosModules.${containerModule}"
  ]
  ++ lib.optional includeImpermanence "          inputs.impermanence.nixosModules.impermanence"
  ++ [
    "          ./configuration.nix"
  ];
  flakeLines = [
    "{"
    "  description = \"vpsAdminOS container\";"
    ""
    "  inputs = {"
  ]
  ++ inputLines
  ++ [
    "  };"
    ""
    "  outputs ="
    "    inputs@{"
    "      nixpkgs,"
    "      vpsadminos,"
    "      ..."
    "    }:"
    "    let"
    "      system = \"x86_64-linux\";"
    "    in"
    "    {"
    "      nixosConfigurations.vps = nixpkgs.lib.nixosSystem {"
    "        inherit system;"
    "        modules = ["
  ]
  ++ moduleLines
  ++ [
    "        ];"
    "        specialArgs = {"
    "          inherit inputs;"
    "        };"
    "      };"
    "    };"
    "}"
  ];
in
pkgs.writeText "flake.nix" (lib.concatStringsSep "\n" flakeLines + "\n")
