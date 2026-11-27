{
  inputs,
  nixpkgs,
  nixpkgsUnstable,
  root,
  self,
}:
let
  supportedSystems = [ "x86_64-linux" ];
  forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  availableKernels = import (root + "/os/packages/linux/available-kernels.nix") {
    lib = nixpkgs.lib;
  };
  kernelVersions = builtins.attrNames availableKernels.kernels;
  ciKernelOutputName =
    kernelVersion:
    "ci-toplevel-kernel-" + nixpkgs.lib.replaceStrings [ "." "-" ] [ "_" "_" ] kernelVersion;
  impermanence = inputs.impermanence;
  flakeLock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
  stableNixpkgsNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.nixpkgs};
  unstableNixpkgsNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.nixpkgsUnstable};
  impermanenceNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.impermanence};
  impermanenceNixpkgsNode = flakeLock.nodes.${impermanenceNode.inputs.nixpkgs};
  homeManagerNode = flakeLock.nodes.${impermanenceNode.inputs."home-manager"};
  osOverlays = import (root + "/os/overlays") {
    inherit (inputs) netlinkrb ruby-lxc;
  };
  livepatchCiTools = forAllSystems (
    system:
    let
      pkgsBase = nixpkgs.legacyPackages.${system};
    in
    pkgsBase.buildEnv {
      name = "livepatch-ci-tools";
      paths = [
        (pkgsBase.lib.getBin pkgsBase.coreutils)
        (pkgsBase.lib.getBin pkgsBase.diffutils)
        (pkgsBase.lib.getBin pkgsBase.findutils)
        (pkgsBase.lib.getBin pkgsBase.gnugrep)
        pkgsBase.jq.bin
      ];
      pathsToLink = [ "/bin" ];
      ignoreCollisions = false;
    }
  );
  vpsadminosGithubRevFile = (root + "/.vpsadminos-git-rev");
  vpsadminosGithubRev =
    if self ? rev then
      self.rev
    else if self ? dirtyRev then
      builtins.substring 0 40 self.dirtyRev
    else if builtins.pathExists vpsadminosGithubRevFile then
      nixpkgs.lib.removeSuffix "\n" (builtins.readFile vpsadminosGithubRevFile)
    else
      null;
  nixpkgsRevision = if nixpkgs ? rev then nixpkgs.rev else null;
  nixpkgsRevisionFor =
    pkgs: if toString pkgs.path == toString nixpkgs.outPath then nixpkgsRevision else null;
  sourceVersionModule = import (root + "/os/lib/source-version.nix") { source = self; };
  containerStableModule = import (root + "/os/lib/nixos-container/stable/vpsadminos.nix");
  containerReleaseModules = {
    "22.11" = import (root + "/os/lib/nixos-container/stable/vpsadminos-22.11.nix");
    "23.05" = import (root + "/os/lib/nixos-container/stable/vpsadminos-23.05.nix");
    "23.11" = import (root + "/os/lib/nixos-container/stable/vpsadminos-23.11.nix");
    "24.05" = import (root + "/os/lib/nixos-container/stable/vpsadminos-24.05.nix");
    "24.11" = import (root + "/os/lib/nixos-container/stable/vpsadminos-24.11.nix");
    "25.05" = import (root + "/os/lib/nixos-container/stable/vpsadminos-25.05.nix");
    "25.11" = import (root + "/os/lib/nixos-container/stable/vpsadminos-25.11.nix");
    "26.05" = import (root + "/os/lib/nixos-container/stable/vpsadminos-26.05.nix");
  };
  containerReleaseAliases = nixpkgs.lib.mapAttrs' (release: module: {
    name = "container_${nixpkgs.lib.replaceStrings [ "." ] [ "_" ] release}";
    value = module;
  }) containerReleaseModules;
  containerStableSelector =
    { lib, ... }:
    {
      # Imports must use the guest evaluator's lib, before config is available.
      imports = [
        (containerReleaseModules.${lib.trivial.release} or (throw (
          "vpsAdminOS: unsupported stable NixOS release '${lib.trivial.release}'. "
          + "Known stable releases: ${nixpkgs.lib.concatStringsSep ", " (builtins.attrNames containerReleaseModules)}. "
          + "Update the vpsadminos input, or explicitly select nixosModules.containerUnstable when using unstable."
        ))
        )
      ];
    };
  containerUnstableModule = import (root + "/os/lib/nixos-container/unstable/vpsadminos.nix");
  testFramework =
    let
      framework = rec {
        inherit sourceVersionModule;
        sourcePath = self.outPath;
        nixpkgsPath = nixpkgs.outPath;
        nixpkgsRevision = if nixpkgs ? rev then nixpkgs.rev else null;
        sourceInputs = {
          inherit (inputs) netlinkrb ruby-lxc;
        };

        makeTest = testFn: args: import (sourcePath + "/tests/make-test.nix") testFn args;
        makeTemplate = templateFn: args: import (sourcePath + "/tests/make-template.nix") templateFn args;
        makeTestLib =
          args: import (sourcePath + "/test-runner/nix/lib.nix") (args // { testFramework = framework; });

        mkTests =
          {
            system,
            pkgsPath ? nixpkgs.outPath,
            testsRoot,
            suiteArgs ? { },
            testConfig ? { },
            configuration ? null,
          }:
          let
            allTests = import (testsRoot + "/all-tests.nix") {
              pkgs = pkgsPath;
              inherit
                system
                suiteArgs
                testConfig
                configuration
                ;
              testFramework = framework;
            };
          in
          builtins.mapAttrs (_: t: t.test.json) allTests;

        mkTestsMeta =
          {
            system,
            pkgsPath ? nixpkgs.outPath,
            testsRoot,
            suiteArgs ? { },
            testConfig ? { },
            configuration ? null,
          }:
          let
            nixpkgs' = import pkgsPath { inherit system; };
            lib' = nixpkgs'.lib;

            testLib = makeTestLib {
              pkgs = pkgsPath;
              inherit
                system
                configuration
                testConfig
                ;
              lib = lib';
              suitePath = testsRoot + "/suite";
              inherit suiteArgs;
            };

            allTests = import (testsRoot + "/all-tests.nix") {
              pkgs = pkgsPath;
              inherit
                system
                suiteArgs
                testConfig
                configuration
                ;
              testFramework = framework;
            };
          in
          testLib.metaFromAllTests allTests;
      };
    in
    framework;
  kernelCacheToplevelModule =
    { config, ... }:
    {
      system.systemBuilderCommands = ''
        ln -sf ${config.boot.kernelPackage.dev} $out/kernel-dev
        ln -sf ${config.boot.kernelForBuiltinsConfig.dev} \
          $out/kernel-for-builtins-config-dev
      '';
    };

  vpsadminosSystem =
    {
      system,
      pkgs ? nixpkgs.legacyPackages.${system},
      modules ? [ ],
      specialArgs ? { },
      configuration ? null,
      platform ? null,
    }:
    let
      flakeVersionInfoModule =
        { lib, pkgs, ... }:
        {
          system.vpsadminos = {
            nixpkgsVersion = pkgs.lib.version;
            nixpkgsRevision = nixpkgsRevisionFor pkgs;
          };
        };
    in
    import (root + "/os/default.nix") (
      {
        inherit
          system
          platform
          ;
        importedPkgs = pkgs;
        nixpkgsPath = pkgs.path;
        modules = modules ++ [
          flakeVersionInfoModule
          sourceVersionModule
        ];
        extraArgs = specialArgs;
        inherit (inputs) netlinkrb ruby-lxc;
      }
      // nixpkgs.lib.optionalAttrs (configuration != null) { inherit configuration; }
    );

  mergeChecks =
    left: right:
    assert nixpkgs.lib.assertMsg (
      builtins.intersectAttrs left right == { }
    ) "Duplicate flake check name";
    left // right;
  livepatchPackageName =
    release: "livepatch-release-${nixpkgs.lib.replaceStrings [ "." ] [ "_" ] release}";
  mkLivepatchContext =
    system:
    let
      catalog = import (root + "/os/livepatches/batches") { lib = nixpkgs.lib; };
      catalogKernelVersions = nixpkgs.lib.unique (map (unit: unit.batch.kernelVersion) catalog);
      systems = builtins.listToAttrs (
        map (kernelVersion: {
          name = kernelVersion;
          value = vpsadminosSystem {
            inherit system;
            modules = [
              (root + "/os/configs/qemu.nix")
              (root + "/tests/configs/vpsadminos/livepatch.nix")
              { boot.kernelVersion = kernelVersion; }
            ];
          };
        }) catalogKernelVersions
      );
      planFor =
        planCatalog: kernelVersion:
        let
          livepatchSystem = systems.${kernelVersion};
          pkgs = livepatchSystem.pkgs;
          kernel = livepatchSystem.config.boot.kernelPackage;
          zfsBuiltinPkg =
            if livepatchSystem.config.boot.zfsBuiltin then livepatchSystem.config.boot.zfsBuiltinPkg else null;
          kpatchBuild = pkgs.callPackage (root + "/os/packages/kpatch-build/default.nix") { };
          configured = (import (root + "/os/livepatches/lib.nix") { lib = pkgs.lib; }).mkConfiguredTarget {
            inherit kernel zfsBuiltinPkg;
            inherit kernelVersion;
            toolchain = kernel.stdenv.cc;
          };
          selected = builtins.filter (unit: unit.batch.kernelVersion == kernelVersion) planCatalog;
          producerAttrs = builtins.listToAttrs (
            map (unit: {
              name = unit.batch.release;
              value = livepatchPackageName unit.batch.release;
            }) selected
          );
        in
        (import (root + "/os/livepatches/qualification.nix") { lib = pkgs.lib; }) {
          builder = {
            kpatchBuild = toString kpatchBuild;
            kpatchRevision = kpatchBuild.src.rev or "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
          };
          catalog = planCatalog;
          inherit producerAttrs system;
          target = configured.kernelTarget;
          plan = true;
          sourceRevision = if vpsadminosGithubRev == null then "unversioned" else vpsadminosGithubRev;
        };
      plans = map (planFor catalog) catalogKernelVersions;
      batchChecks =
        pkgs:
        nixpkgs.lib.foldl' mergeChecks { } (
          nixpkgs.lib.concatMap (
            unit:
            let
              inherit (unit.batch) kernelVersion;
              ordinal =
                member: builtins.fromJSON (pkgs.lib.removePrefix "${kernelVersion}." member.batch.release);
              check =
                (root + "/os/livepatches/batches")
                + "/${kernelVersion}/${toString (ordinal unit)}/qualification/check.nix";
              stack = builtins.filter (
                member: member.batch.kernelVersion == kernelVersion && ordinal member <= ordinal unit
              ) catalog;
            in
            nixpkgs.lib.optional (builtins.pathExists check) {
              "livepatch-qualification-${pkgs.lib.replaceStrings [ "." ] [ "_" ] unit.batch.release}" =
                import check
                  {
                    inherit pkgs;
                    plan = planFor stack kernelVersion;
                    ciTools = livepatchCiTools.${system};
                  };
            }
          ) catalog
        );
      concatField = field: nixpkgs.lib.concatMap (plan: plan.${field}) plans;
      sumCount = field: nixpkgs.lib.foldl' (total: plan: total + (plan.counts.${field} or 0)) 0 plans;
      sets = concatField "sets";
      releases = concatField "releases";
      rows = concatField "rows";
      coverage = concatField "coverage";
      matrixRows = nixpkgs.lib.concatMap (plan: plan.matrix.include) plans;
      qualification = {
        schemaVersion = 1;
        dormant = sets == [ ];
        selectedSets = builtins.length sets;
        inherit
          coverage
          releases
          rows
          sets
          system
          ;
        sourceRevision = if vpsadminosGithubRev == null then "unversioned" else vpsadminosGithubRev;
        matrix.include = matrixRows;
        counts = {
          catalogReleases = builtins.length catalog;
          normalizedReleases = builtins.length releases;
          plannedMembers = sumCount "plannedMembers";
          requiredProfilePlatformTuples = sumCount "requiredProfilePlatformTuples";
          activeOracles = sumCount "activeOracles";
          coverageTuples = builtins.length coverage;
          plannedRows = builtins.length rows;
          matrixRows = builtins.length matrixRows;
        };
      };
      packages = nixpkgs.lib.foldl' (
        result: kernelVersion:
        let
          livepatchSystem = systems.${kernelVersion};
          selected = builtins.filter (unit: unit.batch.kernelVersion == kernelVersion) catalog;
        in
        result
        // builtins.listToAttrs (
          map (unit: {
            name = livepatchPackageName unit.batch.release;
            value = livepatchSystem.config.system.build.livePatchModules.${unit.batch.release};
          }) selected
        )
      ) { } catalogKernelVersions;
    in
    {
      inherit packages qualification batchChecks;
    };
  testsOutputs = import (root + "/nix/flake/tests.nix") {
    inherit
      forAllSystems
      nixpkgs
      root
      testFramework
      ;
  };
  packagesOutputs = import (root + "/nix/flake/packages.nix") {
    inherit
      ciKernelOutputName
      forAllSystems
      homeManagerNode
      impermanence
      impermanenceNixpkgsNode
      impermanenceNode
      kernelCacheToplevelModule
      kernelVersions
      livepatchCiTools
      mkLivepatchContext
      nixpkgs
      nixpkgsUnstable
      osOverlays
      root
      stableNixpkgsNode
      testFramework
      unstableNixpkgsNode
      vpsadminosGithubRev
      vpsadminosSystem
      ;
  };
  devShellOutputs = import (root + "/nix/flake/dev-shells.nix") {
    inherit
      forAllSystems
      inputs
      nixpkgs
      osOverlays
      root
      ;
  };
  defaultCheckOutputs = import (root + "/nix/flake/checks/default.nix") {
    inherit
      forAllSystems
      impermanence
      nixpkgs
      nixpkgsUnstable
      root
      testFramework
      vpsadminosSystem
      ;
  };
  livepatchCheckOutputs = import (root + "/nix/flake/checks/livepatch.nix") {
    inherit
      forAllSystems
      livepatchCiTools
      livepatchPackageName
      mergeChecks
      mkLivepatchContext
      nixpkgs
      root
      testFramework
      ;
  };
in
{
  lib = {
    inherit
      availableKernels
      kernelVersions
      ;
    vpsadminosSystem = vpsadminosSystem;
    livepatchQualificationPlanner = import (root + "/os/livepatches/qualification.nix") {
      lib = nixpkgs.lib;
    };
    inherit testFramework;
  };
  nixpkgsPath = nixpkgs.outPath;

  livepatchQualification = forAllSystems (system: (mkLivepatchContext system).qualification);

  overlays = {
    all = osOverlays;
    default = nixpkgs.lib.composeManyExtensions osOverlays;
    minify = import (root + "/os/overlays/minify.nix");
    osctl = import (root + "/os/overlays/osctl.nix") {
      inherit (inputs) netlinkrb ruby-lxc;
    };
    packages = import (root + "/os/overlays/packages.nix");
    ruby = import (root + "/os/overlays/ruby.nix");
  };

  nixosModules = {
    vpsadminos =
      { pkgs, ... }:
      {
        imports = import (root + "/os/modules/module-list.nix") { nixpkgsPath = pkgs.path; };
        system.vpsadminos = {
          nixpkgsVersion = pkgs.lib.version;
          nixpkgsRevision = nixpkgsRevisionFor pkgs;
        };
      };

    containers = containerReleaseModules;
    container = containerStableSelector;
    containerStable = containerStableSelector;
    containerUnstable = containerUnstableModule;
  }
  // containerReleaseAliases;

  nixosConfigurations = {
    container = containerStableModule;
    containerStable = containerStableModule;
    containerUnstable = containerUnstableModule;
  };

  checks = nixpkgs.lib.mapAttrs (
    system: systemChecks: mergeChecks systemChecks livepatchCheckOutputs.checks.${system}
  ) defaultCheckOutputs.checks;
}
// testsOutputs
// packagesOutputs
// devShellOutputs
