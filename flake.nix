{
  description = "vpsAdminOS flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.impermanence.url = "github:nix-community/impermanence";

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      impermanence = inputs.impermanence;

      vpsadminosSystem =
        {
          system,
          pkgs ? nixpkgs.legacyPackages.${system},
          modules ? [ ],
          specialArgs ? { },
          configuration ? null,
          platform ? null,
        }:
        import ./os/default.nix (
          {
            inherit
              system
              modules
              platform
              ;
            importedPkgs = pkgs;
            nixpkgsPath = pkgs.path;
            extraArgs = specialArgs;
          }
          // nixpkgs.lib.optionalAttrs (configuration != null) { inherit configuration; }
        );
    in
    {
      lib.vpsadminosSystem = vpsadminosSystem;
      nixpkgsPath = nixpkgs.outPath;

      nixosModules.vpsadminos =
        { pkgs, ... }:
        {
          imports = import ./os/modules/module-list.nix { nixpkgsPath = pkgs.path; };
        };

      nixosConfigurations = {
        container = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerStable = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerUnstable = import ./os/lib/nixos-container/unstable/vpsadminos.nix;
      };

      packages = forAllSystems (
        system:
        let
          qemuSystem = vpsadminosSystem {
            inherit system;
            modules = [ ./os/configs/qemu.nix ];
          };

          isoSystem = vpsadminosSystem {
            inherit system;
            modules = [
              { imports = [ ./os/configs/iso.nix ]; }
            ];
          };

          isoLocalSystem = vpsadminosSystem {
            inherit system;
            modules = [
              {
                imports = [
                  ./os/configs/iso.nix
                  ./os/configs/qemu.nix
                ];
              }
            ];
          };

          mkNixosTemplate =
            module:
            nixpkgs.lib.nixosSystem {
              inherit system;
              pkgs = nixpkgs.legacyPackages.${system};
              modules = [ module ];
              specialArgs = { inherit impermanence; };
            };

          templateStableSystem = mkNixosTemplate ./os/lib/nixos-container/stable/minimal.nix;
          templateStableImpermanenceSystem = mkNixosTemplate ./os/lib/nixos-container/stable/impermanence.nix;
          templateUnstableSystem = mkNixosTemplate ./os/lib/nixos-container/unstable/minimal.nix;
          templateUnstableImpermanenceSystem = mkNixosTemplate ./os/lib/nixos-container/unstable/impermanence.nix;
        in
        {
          default = qemuSystem.config.system.build.runvm;
          qemu = qemuSystem.config.system.build.runvm;
          toplevel = qemuSystem.config.system.build.toplevel;
          qemu-script = qemuSystem.config.system.build.runvmScript;
          os-rebuild = qemuSystem.config.system.build.os-rebuild;
          iso = isoSystem.config.system.build.isoImage;
          iso-local = isoLocalSystem.config.system.build.runvm;
          template = templateStableSystem.config.system.build.tarball;
          template-stable = templateStableSystem.config.system.build.tarball;
          template-unstable = templateUnstableSystem.config.system.build.tarball;
          template-impermanence = templateStableImpermanenceSystem.config.system.build.impermanenceTarball;
          template-impermanence-stable =
            templateStableImpermanenceSystem.config.system.build.impermanenceTarball;
          template-impermanence-unstable =
            templateUnstableImpermanenceSystem.config.system.build.impermanenceTarball;
          test-runner = import ./os/packages/test-runner/entry.nix {
            pkgs = nixpkgs.legacyPackages.${system};
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          sys = vpsadminosSystem {
            inherit system;
            modules = [
              (
                { ... }:
                {
                  system.stateVersion = "25.11";
                }
              )
            ];
          };
        in
        {
          os-eval = sys.config.system.build.toplevel;
        }
      );
    };
}
