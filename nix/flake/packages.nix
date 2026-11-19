{
  ciKernelOutputName,
  forAllSystems,
  homeManagerNode,
  impermanence,
  impermanenceNixpkgsNode,
  impermanenceNode,
  kernelCacheToplevelModule,
  kernelVersions,
  livepatchCiTools,
  mkLivepatchContext,
  nixpkgs,
  nixpkgsUnstable,
  osOverlays,
  root,
  stableNixpkgsNode,
  testFramework,
  unstableNixpkgsNode,
  vpsadminosGithubRev,
  vpsadminosSystem,
}:
{
  packages = forAllSystems (
    system:
    let
      pkgsBase = nixpkgs.legacyPackages.${system};
      pkgsWithOverlays = pkgsBase.extend (nixpkgs.lib.composeManyExtensions osOverlays);

      mkQemuSystem =
        extraModules:
        vpsadminosSystem {
          inherit system;
          modules = [ (root + "/os/configs/qemu.nix") ] ++ extraModules;
        };

      qemuSystem = mkQemuSystem [ ];
      ciQemuSystem = mkQemuSystem [ kernelCacheToplevelModule ];

      kernelCiQemuSystems = builtins.listToAttrs (
        map (kernelVersion: {
          name = ciKernelOutputName kernelVersion;
          value = mkQemuSystem [
            kernelCacheToplevelModule
            {
              boot.kernelVersion = kernelVersion;
            }
          ];
        }) kernelVersions
      );

      ciKernelToplevelPackages = builtins.mapAttrs (
        _: kernelSystem: kernelSystem.config.system.build.toplevel
      ) kernelCiQemuSystems;

      isoSystem = vpsadminosSystem {
        inherit system;
        modules = [
          { imports = [ (root + "/os/configs/iso.nix") ]; }
        ];
      };

      isoLocalSystem = vpsadminosSystem {
        inherit system;
        modules = [
          {
            imports = [
              (root + "/os/configs/iso.nix")
              (root + "/os/configs/qemu.nix")
            ];
          }
        ];
      };

      mkNixosTemplate =
        {
          module,
          nixpkgsInput,
          nixpkgsNode,
        }:
        nixpkgsInput.lib.nixosSystem {
          inherit system;
          pkgs = nixpkgsInput.legacyPackages.${system};
          modules = [ module ];
          specialArgs = {
            inherit
              impermanenceNode
              impermanenceNixpkgsNode
              homeManagerNode
              impermanence
              nixpkgsNode
              stableNixpkgsNode
              unstableNixpkgsNode
              vpsadminosGithubRev
              ;
          };
        };

      templateStableSystem = mkNixosTemplate {
        module = (root + "/os/lib/nixos-container/stable/minimal.nix");
        nixpkgsInput = nixpkgs;
        nixpkgsNode = stableNixpkgsNode;
      };
      templateStableImpermanenceSystem = mkNixosTemplate {
        module = (root + "/os/lib/nixos-container/stable/impermanence.nix");
        nixpkgsInput = nixpkgs;
        nixpkgsNode = stableNixpkgsNode;
      };
      templateUnstableSystem = mkNixosTemplate {
        module = (root + "/os/lib/nixos-container/unstable/minimal.nix");
        nixpkgsInput = nixpkgsUnstable;
        nixpkgsNode = unstableNixpkgsNode;
      };
      templateUnstableImpermanenceSystem = mkNixosTemplate {
        module = (root + "/os/lib/nixos-container/unstable/impermanence.nix");
        nixpkgsInput = nixpkgsUnstable;
        nixpkgsNode = unstableNixpkgsNode;
      };
    in
    (
      {
        default = qemuSystem.config.system.build.runvm;
        livepatch-ci-tools = livepatchCiTools.${system};
        qemu = qemuSystem.config.system.build.runvm;
        toplevel = qemuSystem.config.system.build.toplevel;
        ci-toplevel = ciQemuSystem.config.system.build.toplevel;
        qemu-script = qemuSystem.config.system.build.runvmScript;
        vpsadminos-rebuild = qemuSystem.config.system.build.vpsadminos-rebuild;
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
        ctptywrapper = pkgsWithOverlays.ctptywrapper;
        test-runner = import (root + "/test-runner/nix/package.nix") {
          pkgs = pkgsWithOverlays;
        };
      }
      // ciKernelToplevelPackages
      // (mkLivepatchContext system).packages
    )
  );

}
