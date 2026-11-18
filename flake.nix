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
    {
      self,
      nixpkgs,
      nixpkgsUnstable,
      ...
    }@inputs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      availableKernels = import ./os/packages/linux/available-kernels.nix { lib = nixpkgs.lib; };
      kernelVersions = builtins.attrNames availableKernels.kernels;
      ciKernelOutputName =
        kernelVersion:
        "ci-toplevel-kernel-" + nixpkgs.lib.replaceStrings [ "." "-" ] [ "_" "_" ] kernelVersion;
      impermanence = inputs.impermanence;
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      stableNixpkgsNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.nixpkgs};
      unstableNixpkgsNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.nixpkgsUnstable};
      impermanenceNode = flakeLock.nodes.${flakeLock.nodes.root.inputs.impermanence};
      impermanenceNixpkgsNode = flakeLock.nodes.${impermanenceNode.inputs.nixpkgs};
      homeManagerNode = flakeLock.nodes.${impermanenceNode.inputs."home-manager"};
      osOverlays = import ./os/overlays {
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
      vpsadminosGithubRevFile = ./.vpsadminos-git-rev;
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
      sourceVersionModule = import ./os/lib/source-version.nix { source = self; };
      containerStableModule = import ./os/lib/nixos-container/stable/vpsadminos.nix;
      containerReleaseModules = {
        "22.11" = import ./os/lib/nixos-container/stable/vpsadminos-22.11.nix;
        "23.05" = import ./os/lib/nixos-container/stable/vpsadminos-23.05.nix;
        "23.11" = import ./os/lib/nixos-container/stable/vpsadminos-23.11.nix;
        "24.05" = import ./os/lib/nixos-container/stable/vpsadminos-24.05.nix;
        "24.11" = import ./os/lib/nixos-container/stable/vpsadminos-24.11.nix;
        "25.05" = import ./os/lib/nixos-container/stable/vpsadminos-25.05.nix;
        "25.11" = import ./os/lib/nixos-container/stable/vpsadminos-25.11.nix;
        "26.05" = import ./os/lib/nixos-container/stable/vpsadminos-26.05.nix;
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
      containerUnstableModule = import ./os/lib/nixos-container/unstable/vpsadminos.nix;
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
        import ./os/default.nix (
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

      livepatchPackageName =
        release: "livepatch-release-${nixpkgs.lib.replaceStrings [ "." ] [ "_" ] release}";
      mkLivepatchContext =
        system:
        let
          catalog = import ./os/livepatches/batches { lib = nixpkgs.lib; };
          catalogKernelVersions = nixpkgs.lib.unique (map (unit: unit.batch.kernelVersion) catalog);
          systems = builtins.listToAttrs (
            map (kernelVersion: {
              name = kernelVersion;
              value = vpsadminosSystem {
                inherit system;
                modules = [
                  ./os/configs/qemu.nix
                  ./tests/configs/vpsadminos/livepatch.nix
                  { boot.kernelVersion = kernelVersion; }
                ];
              };
            }) catalogKernelVersions
          );
          plans = map (
            kernelVersion:
            let
              livepatchSystem = systems.${kernelVersion};
              pkgs = livepatchSystem.pkgs;
              kernel = livepatchSystem.config.boot.kernelPackage;
              zfsBuiltinPkg =
                if livepatchSystem.config.boot.zfsBuiltin then livepatchSystem.config.boot.zfsBuiltinPkg else null;
              kpatchBuild = pkgs.callPackage ./os/packages/kpatch-build/default.nix { };
              configured = (import ./os/livepatches/lib.nix { lib = pkgs.lib; }).mkConfiguredTarget {
                inherit kernel zfsBuiltinPkg;
                inherit kernelVersion;
                toolchain = kernel.stdenv.cc;
              };
              selected = builtins.filter (unit: unit.batch.kernelVersion == kernelVersion) catalog;
              producerAttrs = builtins.listToAttrs (
                map (unit: {
                  name = unit.batch.release;
                  value = livepatchPackageName unit.batch.release;
                }) selected
              );
            in
            (import ./os/livepatches/qualification.nix { lib = pkgs.lib; }) {
              builder = {
                kpatchBuild = toString kpatchBuild;
                kpatchRevision = kpatchBuild.src.rev or "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
              };
              inherit
                catalog
                producerAttrs
                system
                ;
              target = configured.kernelTarget;
              plan = true;
              sourceRevision = if vpsadminosGithubRev == null then "unversioned" else vpsadminosGithubRev;
            }
          ) catalogKernelVersions;
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
          inherit packages qualification;
        };
    in
    {
      lib = {
        inherit
          availableKernels
          kernelVersions
          ;
        vpsadminosSystem = vpsadminosSystem;
        livepatchQualificationPlanner = import ./os/livepatches/qualification.nix {
          lib = nixpkgs.lib;
        };
        inherit testFramework;
      };
      nixpkgsPath = nixpkgs.outPath;

      livepatchQualification = forAllSystems (system: (mkLivepatchContext system).qualification);

      overlays = {
        all = osOverlays;
        default = nixpkgs.lib.composeManyExtensions osOverlays;
        minify = import ./os/overlays/minify.nix;
        osctl = import ./os/overlays/osctl.nix {
          inherit (inputs) netlinkrb ruby-lxc;
        };
        packages = import ./os/overlays/packages.nix;
        ruby = import ./os/overlays/ruby.nix;
      };

      nixosModules = {
        vpsadminos =
          { pkgs, ... }:
          {
            imports = import ./os/modules/module-list.nix { nixpkgsPath = pkgs.path; };
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

      tests = forAllSystems (
        system:
        let
          allTests = import ./tests/all-tests.nix {
            pkgs = nixpkgs.outPath;
            inherit system;
            suiteArgs = { };
            testConfig = { };
            configuration = null;
            inherit testFramework;
          };
        in
        builtins.mapAttrs (_: t: t.test.json) allTests
      );

      testsMeta = forAllSystems (
        system:
        let
          pkgsPath = nixpkgs.outPath;
          nixpkgs' = import pkgsPath { inherit system; };
          lib' = nixpkgs'.lib;

          testLib = testFramework.makeTestLib {
            pkgs = pkgsPath;
            inherit system;
            lib = lib';
            suitePath = ./tests/suite;
            suiteArgs = { };
            testConfig = { };
            configuration = null;
          };

          allTests = import ./tests/all-tests.nix {
            pkgs = pkgsPath;
            inherit system;
            suiteArgs = { };
            testConfig = { };
            configuration = null;
            inherit testFramework;
          };
        in
        testLib.metaFromAllTests allTests
      );

      packages = forAllSystems (
        system:
        let
          pkgsBase = nixpkgs.legacyPackages.${system};
          pkgsWithOverlays = pkgsBase.extend (nixpkgs.lib.composeManyExtensions osOverlays);

          mkQemuSystem =
            extraModules:
            vpsadminosSystem {
              inherit system;
              modules = [ ./os/configs/qemu.nix ] ++ extraModules;
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
            module = ./os/lib/nixos-container/stable/minimal.nix;
            nixpkgsInput = nixpkgs;
            nixpkgsNode = stableNixpkgsNode;
          };
          templateStableImpermanenceSystem = mkNixosTemplate {
            module = ./os/lib/nixos-container/stable/impermanence.nix;
            nixpkgsInput = nixpkgs;
            nixpkgsNode = stableNixpkgsNode;
          };
          templateUnstableSystem = mkNixosTemplate {
            module = ./os/lib/nixos-container/unstable/minimal.nix;
            nixpkgsInput = nixpkgsUnstable;
            nixpkgsNode = unstableNixpkgsNode;
          };
          templateUnstableImpermanenceSystem = mkNixosTemplate {
            module = ./os/lib/nixos-container/unstable/impermanence.nix;
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
            test-runner = import ./test-runner/nix/package.nix {
              pkgs = pkgsWithOverlays;
            };
          }
          // ciKernelToplevelPackages
          // (mkLivepatchContext system).packages
        )
      );

      devShells = forAllSystems (
        system:
        let
          pkgsBase = nixpkgs.legacyPackages.${system};
          lib = pkgsBase.lib;
          pkgs = pkgsBase.extend (lib.composeManyExtensions osOverlays);

          devShellPrompt = name: ''
            export VPSADMINOS_DEV_SHELL=1
            if [ -n "$PS1" ]; then
              export PS1="(dev:${name}) $PS1"
            fi
          '';

          mkRubyBundlerShell =
            {
              name,
              packages,
              pathExtra ? "",
              extraHook ? "",
            }:
            pkgs.mkShell {
              inherit name;
              packages = packages;
              shellHook = ''
                mkdir -p /tmp/dev-ruby-gems
                export GEM_HOME="/tmp/dev-ruby-gems"
                export GEM_PATH="$GEM_HOME:$PWD/lib"
                export PATH="$GEM_HOME/bin:$PATH${lib.optionalString (pathExtra != "") ":${pathExtra}"}"

                BUNDLE="$GEM_HOME/bin/bundle"

                [ ! -x "$BUNDLE" ] && ${pkgs.ruby}/bin/gem install bundler

                export BUNDLE_PATH="$GEM_HOME"
                export BUNDLE_GEMFILE="$PWD/Gemfile"
                export NETLINKRB_PATH="''${NETLINKRB_PATH:-${inputs.netlinkrb}}"
                export RUBY_LXC_PATH="''${RUBY_LXC_PATH:-${inputs.ruby-lxc}}"

                $BUNDLE install

                export RUBYOPT=-rbundler/setup
              ''
              + extraHook
              + (devShellPrompt name);
            };

          osctldPath = with pkgs; [
            apparmor-parser
            coreutils
            findutils
            iproute2
            getent
            glibc.bin
            gzip
            lxc
            mbuffer
            nettools
            gnutar
            openssh
            shadow
            util-linux
            devcgprog
            bpftools
          ];

          osctldPathJoined = lib.concatMapStringsSep ":" (s: "${s}/bin") osctldPath;

          osctldConfig = {
            debug = true;
            apparmor_paths = [ "${pkgs.apparmor-profiles}/etc/apparmor.d" ];
            ctstartmenu = "${pkgs.ctstartmenu}/bin/ctstartmenu";
            lock_registry = true;
            cpu_scheduler.enable = true;
          };

          osctldConfigFile = pkgs.writeText "osctld-config.json" (builtins.toJSON osctldConfig);

          vpsadminosShell = pkgs.mkShell {
            name = "vpsadminos";
            packages = with pkgs; [
              bundix
              git
              gnumake
              libffi
              lxc
              mkdocs
              ncurses
              nixfmt
              nixfmt-tree
              ruby_vpsadminos
            ];
            shellHook = ''
              # Work around TMPDIR not being set correctly in development shells
              export TMPDIR=/tmp

              export GEM_HOME="$(pwd)/.gems"
              export PATH="$(ruby -e 'puts Gem.bindir'):$PATH"
              export RUBYLIB="$GEM_HOME"
              export NETLINKRB_PATH="''${NETLINKRB_PATH:-${inputs.netlinkrb}}"
              export RUBY_LXC_PATH="''${RUBY_LXC_PATH:-${inputs.ruby-lxc}}"
              gem install --no-document bundler

              # Purity disabled because of prism gem, which has a native extension.
              # The extension has its header files in .gems, which gets stripped but
              # cc wrapper in Nix. Without NIX_ENFORCE_PURITY=0, we get prism.h not found
              # error.
              NIX_ENFORCE_PURITY=0 bundle install

              [ -f shellhook.local.sh ] && . shellhook.local.sh
            ''
            + devShellPrompt "vpsadminos";
          };
        in
        {
          default = vpsadminosShell;
          vpsadminos = vpsadminosShell;

          ctptywrapper = pkgsBase.mkShell {
            name = "ctptywrapper";
            packages = with pkgsBase; [
              git
              cargo
              rustc
              rustfmt
            ];
            shellHook = devShellPrompt "ctptywrapper";
          };

          ctstartmenu = pkgsBase.mkShell {
            name = "ctstartmenu";
            packages = with pkgsBase; [
              git
              go
              gotools
            ];
            shellHook = devShellPrompt "ctstartmenu";
          };

          converter = mkRubyBundlerShell {
            name = "converter";
            packages = with pkgs; [
              ruby
              git
              zlib
              openssl
            ];
          };

          libosctl = mkRubyBundlerShell {
            name = "libosctl";
            packages = with pkgs; [
              libffi
              git
              openssl
              ruby
              zlib
            ];
          };

          osctld = mkRubyBundlerShell {
            name = "osctld";
            packages = with pkgs; [
              ruby
              git
              libffi
              lxc
              zlib
              openssl
            ];
            pathExtra = osctldPathJoined;
            extraHook = ''
              run-osctld() {
                bundle exec bin/osctld --config ${osctldConfigFile}
              }

              run-memory-profiler-osctld() {
                bundle exec $GEM_HOME/ruby/*/bin/ruby-memory-profiler \
                  bin/osctld -- --no-supervisor --config ${osctldConfigFile}
              }
            '';
          };

          osctl-exporter = mkRubyBundlerShell {
            name = "osctl-exporter";
            packages = with pkgs; [
              git
              ncurses
              openssl
              ruby
            ];
          };

          osctl-exportfs = mkRubyBundlerShell {
            name = "osctl-exportfs";
            packages = with pkgs; [
              git
              openssl
              ruby
              zlib
            ];
          };

          osctl-image = mkRubyBundlerShell {
            name = "osctl-image";
            packages = with pkgs; [
              git
              ncurses
              openssl
              ruby
              zlib
            ];
          };

          osctl-oomd = mkRubyBundlerShell {
            name = "osctl-oomd";
            packages = with pkgs; [
              libffi
              git
              ncurses
              openssl
              ruby
            ];
          };

          osctl-repo = mkRubyBundlerShell {
            name = "osctl-repo";
            packages = with pkgs; [
              ruby
              git
              zlib
              openssl
            ];
          };

          osctl = mkRubyBundlerShell {
            name = "osctl";
            packages = with pkgs; [
              libffi
              git
              openssl
              ncurses
              ruby
              zlib
            ];
          };

          osup = mkRubyBundlerShell {
            name = "osup";
            packages = with pkgs; [
              ruby
              git
            ];
          };

          osvm = mkRubyBundlerShell {
            name = "osvm";
            packages = with pkgs; [
              ruby
              git
            ];
          };

          svctl = mkRubyBundlerShell {
            name = "svctl";
            packages = with pkgs; [
              ruby
              git
              zlib
            ];
          };

          test-runner = pkgs.mkShell {
            name = "test-runner";
            packages = with pkgs; [
              libffi
              git
              ruby_vpsadminos
              zlib
            ];
            shellHook = ''
              REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
              TEST_RUNNER_ROOT="$REPO_ROOT/test-runner"
              GEM_HOME="$TEST_RUNNER_ROOT/.gems"

              export REPO_ROOT
              export TEST_RUNNER_ROOT
              export TEST_RUNNER_NIXPKGS_PATH=${pkgs.path}
              export TEST_RUNNER_NIX_SYSTEM=${pkgs.stdenv.hostPlatform.system}
              export GEM_HOME
              export GEM_PATH="$GEM_HOME:$TEST_RUNNER_ROOT/lib"
              export PATH="$GEM_HOME/bin:$PATH"

              mkdir -p "$GEM_HOME"

              BUNDLE="$GEM_HOME/bin/bundle"

              if [ ! -x "$BUNDLE" ]; then
                ${pkgs.ruby_vpsadminos}/bin/gem install bundler --no-document
              fi

              export BUNDLE_PATH="$GEM_HOME"
              export BUNDLE_GEMFILE="$TEST_RUNNER_ROOT/Gemfile"

              # prism native extension needs relaxed purity for headers in GEM_HOME
              NIX_ENFORCE_PURITY=0 $BUNDLE install

              export RUBYOPT=-rbundler/setup
            ''
            + devShellPrompt "test-runner";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          stackManagerUnit = import ./os/modules/services/livepatches/tests/default.nix {
            inherit pkgs;
          };
          stackManagerRendered = import ./tests/suite/kernel/livepatch-set.nix {
            pkgs = nixpkgs.outPath;
            inherit system testFramework;
            templateArgs.row = {
              managerFixture = true;
              rowId = "production-manager-private-stack";
            };
          };
          stackManagerReceipt = pkgs.writeText "livepatch-stack-manager-render.json" (
            builtins.toJSON {
              instance = stackManagerRendered.instance;
              name = stackManagerRendered.config.name;
              machines = builtins.attrNames stackManagerRendered.config.machines;
              tags = stackManagerRendered.config.tags;
            }
          );
          sys = vpsadminosSystem {
            inherit system;
            modules = [
              (
                { ... }:
                {
                  system.stateVersion = "26.05";
                }
              )
            ];
          };
          qualificationPlanner = import ./os/livepatches/qualification.nix { lib = pkgs.lib; };
          qualificationTarget.kernelVersion = "6.12.113";
          qualificationProfiles = [
            "set/vendor-aged-transition"
            "set/vendor-busy-transition"
            "set/vendor-failure-recovery"
            "set/vendor-lifecycle"
          ];
          qualificationPlatforms = {
            amd.runnerClass = "amd-livepatch";
            intel.runnerClass = "intel-kvm";
          };
          qualificationProfileSettings."set/vendor-aged-transition" = {
            developmentDwellSeconds = 300;
            releaseDwellSeconds = 1800;
            selectedEvidenceClass = "development-short";
          };
          mkQualificationOracle = fixId: oracleId: {
            schemaVersion = 1;
            inherit fixId;
            oracles = [
              {
                id = oracleId;
                scope = "fix";
                role = "fixed-path";
                applicablePlatforms = [
                  "amd"
                  "intel"
                ];
                timeoutClass = "oracle";
                expectedOutcome = "success";
                testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/${fixId}.nix";
                validator = "os/livepatches/batches/6.12.113/1/qualification/validators/${fixId}.sh";
              }
            ];
          };
          mkQualificationEntry =
            ordinal: fixId: oracleId:
            let
              release = "6.12.113.${toString ordinal}";
            in
            {
              batch = {
                inherit release;
                kernelTarget.kernelVersion = "6.12.113";
                payloadRevision = 1;
                unameLevel.releaseOrdinal = ordinal;
                lineage.predecessorBatch =
                  if ordinal == 1 then null else { release = "6.12.113.${toString (ordinal - 1)}"; };
                fixes = [ { id = fixId; } ];
                oracleIds = [ oracleId ];
              };
              qualification = {
                schemaVersion = 1;
                inherit release;
                requiredGenericProfiles = qualificationProfiles;
                platforms = qualificationPlatforms;
                profileSettings = qualificationProfileSettings;
                oracles = [ (mkQualificationOracle fixId oracleId) ];
              };
            };
          qualificationRoot = mkQualificationEntry 1 "fix-a" "oracle-a";
          qualificationSuccessor = mkQualificationEntry 2 "fix-b" "oracle-b";
          mkQualificationPlan =
            entries:
            qualificationPlanner {
              builder = { };
              catalog = [ ];
              target = qualificationTarget;
              normalizedReleases = entries;
              plan = true;
              producerAttrs = builtins.listToAttrs (
                map (entry: {
                  name = entry.batch.release;
                  value = livepatchPackageName entry.batch.release;
                }) entries
              );
              sourceRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
              inherit system;
            };
          qualificationPlanOne = mkQualificationPlan [ qualificationRoot ];
          qualificationPlanTwo = mkQualificationPlan [
            qualificationRoot
            qualificationSuccessor
          ];
          withQualificationProfileSettings =
            entry: settings:
            entry
            // {
              qualification = entry.qualification // {
                profileSettings."set/vendor-aged-transition" = settings;
              };
            };
          qualificationReleaseSelection = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                selectedEvidenceClass = "release";
              }
            ))
          ];
          qualificationActualPlan = (mkLivepatchContext system).qualification;
          qualificationActualSets = qualificationActualPlan.sets;
          qualificationActualCatalog = import ./os/livepatches/batches { lib = nixpkgs.lib; };
          qualificationActualSelectedCatalogForSet =
            set:
            builtins.filter (unit: unit.batch.kernelVersion == set.kernelVersion) qualificationActualCatalog;
          qualificationActualTipForSet = set: nixpkgs.lib.last (qualificationActualSelectedCatalogForSet set);
          qualificationActualCatalogReleases = map (unit: unit.batch.release) qualificationActualCatalog;
          qualificationActualSortedCatalogReleases = builtins.sort builtins.lessThan qualificationActualCatalogReleases;
          qualificationActualPlannedReleases = map (
            release: release.release
          ) qualificationActualPlan.releases;
          qualificationActualSortedPlannedReleases = builtins.sort builtins.lessThan qualificationActualPlannedReleases;
          qualificationActualMemberReleases = builtins.concatLists (
            map (set: map (member: member.release) set.members) qualificationActualSets
          );
          qualificationActualSetRows = builtins.filter (row: row.scope == "set") qualificationActualPlan.rows;
          qualificationActualFixRows = builtins.filter (row: row.scope == "fix") qualificationActualPlan.rows;
          qualificationActualExpectedAgingForSet =
            set:
            let
              tip = qualificationActualTipForSet set;
              settings = tip.qualification.profileSettings."set/vendor-aged-transition";
            in
            {
              checkpointSeconds = 60;
              inherit (settings)
                developmentDwellSeconds
                releaseDwellSeconds
                ;
              dwellSeconds =
                if settings.selectedEvidenceClass == "development-short" then
                  settings.developmentDwellSeconds
                else
                  settings.releaseDwellSeconds;
              evidenceClass = settings.selectedEvidenceClass;
            };
          qualificationActualExpectedAgingBySet = builtins.listToAttrs (
            map (set: {
              name = set.id;
              value = qualificationActualExpectedAgingForSet set;
            }) qualificationActualSets
          );
          qualificationActualExpectedOraclePlatforms = builtins.concatLists (
            map (
              set:
              builtins.concatLists (
                map (
                  oracle:
                  map (platformId: {
                    inherit (oracle) fixId;
                    oracleId = oracle.id;
                    inherit platformId;
                    setId = set.id;
                  }) oracle.platforms
                ) set.oracles
              )
            ) qualificationActualSets
          );
          qualificationActualExpectedFixMembership = builtins.sort builtins.lessThan (
            map (
              item: "${item.setId}\t${item.fixId}\t${item.oracleId}\t${item.platformId}"
            ) qualificationActualExpectedOraclePlatforms
          );
          qualificationActualFixMembership = builtins.sort builtins.lessThan (
            map (row: "${row.setId}\t${row.fixId}\t${row.id}\t${row.platformId}") qualificationActualFixRows
          );
          qualificationActualExpectedCoverageMembership = builtins.sort builtins.lessThan (
            map (
              item: "${item.setId}\t${item.oracleId}\t${item.platformId}"
            ) qualificationActualExpectedOraclePlatforms
          );
          qualificationActualCoverageMembership = builtins.sort builtins.lessThan (
            map (item: "${item.setId}\t${item.oracleId}\t${item.platformId}") qualificationActualPlan.coverage
          );
          qualificationActualNfsCatalogUnits = builtins.filter (
            unit:
            builtins.any (
              manifest:
              manifest.fixId == "nfs-sysfs-client-lifetime"
              && builtins.any (oracle: oracle.id == "nfs-client-operation-safety") manifest.oracles
            ) unit.qualification.oracles
          ) qualificationActualCatalog;
          qualificationActualNfsCatalogUnit =
            assert builtins.length qualificationActualNfsCatalogUnits == 1;
            builtins.head qualificationActualNfsCatalogUnits;
          qualificationActualNfsSets = builtins.filter (
            set:
            set.kernelVersion == qualificationActualNfsCatalogUnit.batch.kernelVersion
            && builtins.any (
              oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
            ) set.oracles
          ) qualificationActualSets;
          qualificationActualNfsSet =
            assert builtins.length qualificationActualNfsSets == 1;
            builtins.head qualificationActualNfsSets;
          qualificationActualNfsSetRows = builtins.filter (
            row: row.scope == "set" && row.setId == qualificationActualNfsSet.id
          ) qualificationActualPlan.rows;
          qualificationActualNfsRows = builtins.filter (
            row:
            row.scope == "fix"
            && row.setId == qualificationActualNfsSet.id
            && row.fixId == "nfs-sysfs-client-lifetime"
            && row.id == "nfs-client-operation-safety"
            && row.oracleIds == [ "nfs-client-operation-safety" ]
          ) qualificationActualPlan.rows;
          qualificationActualNfsFixRows = builtins.filter (
            row: row.platformId == "amd"
          ) qualificationActualNfsRows;
          qualificationActualFixRow =
            assert builtins.length qualificationActualNfsFixRows == 1;
            builtins.head qualificationActualNfsFixRows;
          qualificationActualNfsOracles = builtins.filter (
            oracle: oracle.fixId == "nfs-sysfs-client-lifetime" && oracle.id == "nfs-client-operation-safety"
          ) qualificationActualNfsSet.oracles;
          qualificationActualOracle =
            assert builtins.length qualificationActualNfsOracles == 1;
            builtins.head qualificationActualNfsOracles;
          qualificationActualFlakeLockSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
          qualificationActualSyntheticHash =
            kind: set: member:
            builtins.hashString "sha256" "${kind}:${set.kernelVersion}:${member.release}";
          qualificationActualIdentity =
            setIndex: memberIndex: set: member:
            let
              releaseTag = nixpkgs.lib.replaceStrings [ "." ] [ "_" ] member.release;
              syntheticHash = kind: qualificationActualSyntheticHash kind set member;
              producerKey = "${nixpkgs.lib.fixedWidthNumber 16 (setIndex + 1)}${
                nixpkgs.lib.fixedWidthNumber 16 (memberIndex + 1)
              }";
              producer = "/nix/store/${producerKey}-synthetic-producer-${releaseTag}";
            in
            {
              inherit producer;
              module = "${producer}/synthetic-${releaseTag}.ko";
              moduleName = "synthetic_livepatch_${toString (setIndex + 1)}_${toString member.releaseOrdinal}";
              moduleSha256 = syntheticHash "module";
              targetId = "synthetic-target-${set.kernelVersion}";
              inputDigest = syntheticHash "input";
              manifestSha256 = syntheticHash "manifest";
              inspectionSha256 = syntheticHash "inspection";
              closureSha256 = syntheticHash "closure";
              vermagic = "${set.kernelVersion} synthetic";
              sourceRevision = qualificationActualPlan.sourceRevision;
              flakeLockSha256 = qualificationActualFlakeLockSha256;
            };
          qualificationActualAudit =
            set: member: identity:
            let
              syntheticHash = kind: qualificationActualSyntheticHash kind set member;
            in
            {
              deriver = "${identity.producer}.drv";
              requisites = [ identity.producer ];
              expectedInspectionSha256 = syntheticHash "expected-inspection";
              frameworkSha256 = syntheticHash "framework";
              generatedHeaderSha256 = syntheticHash "generated-header";
              changedObjectsSha256 = syntheticHash "changed-objects";
              buildLogSha256 = syntheticHash "build-log";
              buildLogIdentity = "per-realization-only";
            };
          qualificationActualCaptureSets = nixpkgs.lib.imap0 (setIndex: set: {
            id = set.id;
            members = nixpkgs.lib.imap0 (
              memberIndex: member:
              let
                identity = qualificationActualIdentity setIndex memberIndex set member;
              in
              {
                inherit (member) release;
                inherit identity;
                audit = qualificationActualAudit set member identity;
              }
            ) set.members;
          }) qualificationActualSets;
          qualificationActualCapturedMembers = builtins.concatLists (
            map (set: set.members) qualificationActualCaptureSets
          );
          qualificationActualCapture = {
            schemaVersion = 1;
            sourceRevision = qualificationActualPlan.sourceRevision;
            flakeLockSha256 = qualificationActualFlakeLockSha256;
            rawBuildLogIdentity = "per-realization-only";
            selectedSets = builtins.length qualificationActualCaptureSets;
            counts = {
              plannedMembers = builtins.length qualificationActualCapturedMembers;
              capturedMembers = builtins.length qualificationActualCapturedMembers;
            };
            sets = qualificationActualCaptureSets;
          };
          qualificationActualNfsCapturedSets = builtins.filter (
            set: set.id == qualificationActualNfsSet.id
          ) qualificationActualCaptureSets;
          qualificationActualNfsCapturedSet =
            assert builtins.length qualificationActualNfsCapturedSets == 1;
            builtins.head qualificationActualNfsCapturedSets;
          qualificationNfsCompatibilitySetId = (builtins.head qualificationActualNfsSet.members).release;
          qualificationNfsCompatibilityReleases = builtins.filter (
            release: release.release == qualificationNfsCompatibilitySetId
          ) qualificationActualPlan.releases;
          qualificationNfsCompatibilityRelease =
            assert builtins.length qualificationNfsCompatibilityReleases == 1;
            builtins.head qualificationNfsCompatibilityReleases;
          qualificationNfsCompatibilityAging =
            (builtins.head (
              builtins.filter (row: row.role == "aged-transition") qualificationReleaseSelection.rows
            )).aging;
          rebaseQualificationNfsCompatibilityRow =
            row:
            row
            // {
              setId = qualificationNfsCompatibilitySetId;
              rowId =
                nixpkgs.lib.replaceStrings
                  [ "${qualificationActualNfsSet.id}--" ]
                  [
                    "${qualificationNfsCompatibilitySetId}--"
                  ]
                  row.rowId;
            }
            // nixpkgs.lib.optionalAttrs ((row.role or null) == "aged-transition") {
              aging = qualificationNfsCompatibilityAging;
            };
          qualificationNfsCompatibilityRows = map rebaseQualificationNfsCompatibilityRow (
            qualificationActualNfsSetRows ++ qualificationActualNfsRows
          );
          qualificationNfsCompatibilityCoverage = map rebaseQualificationNfsCompatibilityRow (
            builtins.filter (
              entry:
              entry.setId == qualificationActualNfsSet.id && entry.oracleId == "nfs-client-operation-safety"
            ) qualificationActualPlan.coverage
          );
          qualificationNfsCompatibilitySet = qualificationActualNfsSet // {
            id = qualificationNfsCompatibilitySetId;
            tipRelease = qualificationNfsCompatibilitySetId;
            members = [ (builtins.head qualificationActualNfsSet.members) ];
            oracleIds = [ "nfs-client-operation-safety" ];
            oracles = [ qualificationActualOracle ];
          };
          qualificationNfsCompatibilityPlan = qualificationActualPlan // {
            selectedSets = 1;
            releases = [ qualificationNfsCompatibilityRelease ];
            sets = [ qualificationNfsCompatibilitySet ];
            rows = qualificationNfsCompatibilityRows;
            coverage = qualificationNfsCompatibilityCoverage;
            matrix.include = compactQualificationRows qualificationNfsCompatibilityRows;
            counts = {
              catalogReleases = 1;
              normalizedReleases = 1;
              plannedMembers = builtins.length qualificationNfsCompatibilitySet.members;
              requiredProfilePlatformTuples = builtins.length qualificationActualNfsSetRows;
              activeOracles = builtins.length qualificationNfsCompatibilitySet.oracles;
              coverageTuples = builtins.length qualificationNfsCompatibilityCoverage;
              plannedRows = builtins.length qualificationNfsCompatibilityRows;
              matrixRows = builtins.length qualificationNfsCompatibilityRows;
            };
          };
          qualificationNfsCompatibilityCapture = qualificationActualCapture // {
            selectedSets = 1;
            counts = {
              plannedMembers = 1;
              capturedMembers = 1;
            };
            sets = [
              {
                id = qualificationNfsCompatibilitySetId;
                members = [ (builtins.head qualificationActualNfsCapturedSet.members) ];
              }
            ];
          };
          qualificationNfsCompatibilityFixRow = builtins.head (
            builtins.filter (
              row: row.scope == "fix" && row.platformId == "amd"
            ) qualificationNfsCompatibilityRows
          );
          qualificationActualNfsHelper =
            import ./os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix
              {
                capture = qualificationActualCapture;
                oracle = qualificationActualOracle;
                plan = qualificationActualPlan;
                inherit pkgs;
                qualificationSet = qualificationActualNfsSet;
                row = qualificationActualFixRow;
              };
          qualificationNfsCompatibilityHelper =
            import ./os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix
              {
                capture = qualificationNfsCompatibilityCapture;
                oracle = qualificationActualOracle;
                plan = qualificationNfsCompatibilityPlan;
                inherit pkgs;
                qualificationSet = qualificationNfsCompatibilitySet;
                row = qualificationNfsCompatibilityFixRow;
              };
          qualificationWorkload = import ./tests/suite/kernel/livepatch-set/workload.nix {
            inherit pkgs;
          };
          qualificationWorkloadPackage = builtins.head (
            (builtins.head qualificationWorkload.modules).environment.systemPackages
          );
          mapQualificationOracle =
            transform: entry:
            entry
            // {
              qualification = entry.qualification // {
                oracles = map (
                  manifest:
                  manifest
                  // {
                    oracles = map transform manifest.oracles;
                  }
                ) entry.qualification.oracles;
              };
            };
          qualificationEvaluationFails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
          qualificationMissingProfile = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  requiredGenericProfiles = [ "set/vendor-lifecycle" ];
                };
              }
            )
          ];
          qualificationMissingAgedSettings = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = builtins.removeAttrs qualificationRoot.qualification [ "profileSettings" ];
              }
            )
          ];
          qualificationPartialAgedSettings = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              builtins.removeAttrs qualificationProfileSettings."set/vendor-aged-transition" [
                "releaseDwellSeconds"
              ]
            ))
          ];
          qualificationExtraAgedSettings = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                unexpected = true;
              }
            ))
          ];
          qualificationUnknownAgedClass = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                selectedEvidenceClass = "unknown";
              }
            ))
          ];
          qualificationNonIntegerAgedSettings = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                developmentDwellSeconds = 300.5;
              }
            ))
          ];
          qualificationNonPositiveAgedSettings = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                developmentDwellSeconds = 0;
              }
            ))
          ];
          qualificationNonIncreasingAgedSettings = mkQualificationPlan [
            (withQualificationProfileSettings qualificationRoot (
              qualificationProfileSettings."set/vendor-aged-transition"
              // {
                developmentDwellSeconds = 1800;
              }
            ))
          ];
          qualificationMissingOracle = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  oracles = [ ];
                };
              }
            )
          ];
          qualificationDuplicateOracle = mkQualificationPlan [
            qualificationRoot
            (
              qualificationSuccessor
              // {
                batch = qualificationSuccessor.batch // {
                  oracleIds = [ "oracle-a" ];
                };
                qualification = qualificationSuccessor.qualification // {
                  oracles = [ (mkQualificationOracle "fix-b" "oracle-a") ];
                };
              }
            )
          ];
          qualificationAuthoredRunnerClass = mkQualificationPlan [
            (mapQualificationOracle (oracle: oracle // { runnerClass = "amd-livepatch"; }) qualificationRoot)
          ];
          qualificationFlatOraclePath = mkQualificationPlan [
            (mapQualificationOracle (
              oracle:
              oracle
              // {
                testAdapter = "os/livepatches/batches/6.12.113.1/qualification/helpers/fix-a.nix";
              }
            ) qualificationRoot)
          ];
          qualificationLeadingZeroOraclePath = mkQualificationPlan [
            (mapQualificationOracle (
              oracle:
              oracle
              // {
                validator = "os/livepatches/batches/6.12.113/01/qualification/validators/fix-a.sh";
              }
            ) qualificationRoot)
          ];
          qualificationMissingPlatformRunner = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  platforms = qualificationPlatforms // {
                    amd = { };
                  };
                };
              }
            )
          ];
          qualificationEmptyPlatformRunner = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  platforms = qualificationPlatforms // {
                    amd.runnerClass = "";
                  };
                };
              }
            )
          ];
          qualificationWrongPlatformRunner = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  platforms = qualificationPlatforms // {
                    amd.runnerClass = "intel-kvm";
                  };
                };
              }
            )
          ];
          qualificationUnknownApplicablePlatform = mkQualificationPlan [
            (mapQualificationOracle (
              oracle:
              oracle
              // {
                applicablePlatforms = [
                  "amd"
                  "arm"
                ];
              }
            ) qualificationRoot)
          ];
          qualificationAbsentApplicablePlatform = mkQualificationPlan [
            (mapQualificationOracle (
              oracle: builtins.removeAttrs oracle [ "applicablePlatforms" ]
            ) qualificationRoot)
          ];
          qualificationDuplicateApplicablePlatform = mkQualificationPlan [
            (mapQualificationOracle (
              oracle:
              oracle
              // {
                applicablePlatforms = [
                  "amd"
                  "amd"
                ];
              }
            ) qualificationRoot)
          ];
          qualificationUnsupportedIntel = mkQualificationPlan [
            (
              qualificationRoot
              // {
                qualification = qualificationRoot.qualification // {
                  platforms = qualificationPlatforms // {
                    intel = qualificationPlatforms.intel // {
                      unsupportedReason = "Intel qualification runner unavailable";
                    };
                  };
                };
              }
            )
          ];
          qualificationOracleRows = builtins.filter (row: row.scope == "fix") qualificationPlanOne.rows;
          qualificationRootSet = builtins.head qualificationPlanOne.sets;
          qualificationRootRow = builtins.head (
            builtins.filter (row: row.scope == "set") qualificationPlanOne.rows
          );
          qualificationSuccessorSet = builtins.head qualificationPlanTwo.sets;
          qualificationFixRow = builtins.head qualificationOracleRows;
          qualificationRubyJson = import ./tests/suite/kernel/livepatch-ruby-json.nix {
            lib = pkgs.lib;
          };
          qualificationOracleScript = ''
            producer = shell(identity.fetch('producer'))
            module_path = shell(identity.fetch('module'))
            evidence = "#{producer}/share/vpsadminos-livepatch"
            expected_sha = "#{identity.fetch('moduleSha256')}"
            machine.succeeds("test -f #{module_path}")
            literal_quotes = %q("double" and 'single')
            literal_backslash = 'C:\\livepatch\\module'
            payload_lines = <<~'PAYLOAD'
              before
            VPSADMINOS_LIVEPATCH_JSON_END
              after
            PAYLOAD
          '';
          qualificationOracleScriptMap = builtins.listToAttrs [
            {
              name = qualificationFixRow.id;
              value = qualificationOracleScript;
            }
          ];
          qualificationOracleScriptFile = pkgs.writeText "livepatch-qualification-oracle.rb" (
            qualificationOracleScript
          );
          qualificationRootSetJsonFile = pkgs.writeText "livepatch-qualification-root-set.json" (
            builtins.toJSON qualificationRootSet
          );
          qualificationRootRowJsonFile = pkgs.writeText "livepatch-qualification-root-row.json" (
            builtins.toJSON qualificationRootRow
          );
          qualificationSuccessorSetJsonFile = pkgs.writeText "livepatch-qualification-successor-set.json" (
            builtins.toJSON qualificationSuccessorSet
          );
          qualificationFixRowJsonFile = pkgs.writeText "livepatch-qualification-fix-row.json" (
            builtins.toJSON qualificationFixRow
          );
          qualificationOracleScriptMapJsonFile = pkgs.writeText "livepatch-qualification-oracle-map.json" (
            builtins.toJSON qualificationOracleScriptMap
          );
          qualificationSerializationCheck = pkgs.writeText "livepatch-qualification-serialization.rb" ''
            require 'digest'
            require 'json'

            root_set = ${qualificationRubyJson qualificationRootSet}
            root_row = ${qualificationRubyJson qualificationRootRow}
            successor_set = ${qualificationRubyJson qualificationSuccessorSet}
            fix_row = ${qualificationRubyJson qualificationFixRow}
            oracle_scripts = ${qualificationRubyJson qualificationOracleScriptMap}

            raise 'root predecessor is not nil' unless root_set.fetch('members').fetch(0).fetch('predecessorRelease').nil?
            raise 'root set did not round-trip' unless JSON.generate(root_set) == File.binread(ARGV.fetch(1))
            raise 'root row did not round-trip' unless JSON.generate(root_row) == File.binread(ARGV.fetch(2))
            raise 'row list changed' unless root_row.fetch('oracleIds') == []
            raise 'row platform map changed' unless root_row.fetch('platform').fetch('supported') == true
            raise 'successor predecessor changed' unless successor_set.fetch('members').fetch(1).fetch('predecessorRelease') == '6.12.113.1'
            raise 'successor set did not round-trip' unless JSON.generate(successor_set) == File.binread(ARGV.fetch(3))
            raise 'fix row did not round-trip' unless JSON.generate(fix_row) == File.binread(ARGV.fetch(4))
            raise 'oracle map did not round-trip' unless JSON.generate(oracle_scripts) == File.binread(ARGV.fetch(5))

            oracle_script = oracle_scripts.fetch(fix_row.fetch('id'))
            expected_oracle = File.binread(ARGV.fetch(0))
            raise 'oracle bytes changed' unless oracle_script.b == expected_oracle.b
            raise 'oracle SHA changed' unless Digest::SHA256.hexdigest(oracle_script.b) == Digest::SHA256.file(ARGV.fetch(0)).hexdigest
            raise 'producer interpolation changed' unless oracle_script.include?('#{producer}')
            raise 'identity interpolation changed' unless oracle_script.include?(%q(#{identity.fetch('moduleSha256')}))
            raise 'module path interpolation changed' unless oracle_script.include?('#{module_path}')
            raise 'decoded delimiter line changed' unless oracle_script.lines.map(&:chomp).include?('VPSADMINOS_LIVEPATCH_JSON_END')
          '';
          qualificationUnsupportedOracleRows = builtins.filter (
            row: row.scope == "fix"
          ) qualificationUnsupportedIntel.rows;
          qualificationAgedRows = builtins.filter (
            row: row.role == "aged-transition"
          ) qualificationPlanOne.rows;
          qualificationReleaseAgedRows = builtins.filter (
            row: row.role == "aged-transition"
          ) qualificationReleaseSelection.rows;
          qualificationActualAgedRows = builtins.filter (
            row: row.role == "aged-transition"
          ) qualificationActualPlan.rows;
          compactQualificationRows =
            rows:
            map (row: {
              inherit (row)
                expectedOutcome
                profileId
                rowId
                runnerClass
                setId
                timeoutClass
                ;
            }) rows;
          qualificationPlanOneFile = pkgs.writeText "livepatch-plan-one.json" (
            builtins.toJSON qualificationPlanOne
          );
          qualificationPlanTwoFile = pkgs.writeText "livepatch-plan-two.json" (
            builtins.toJSON qualificationPlanTwo
          );
          qualificationActualPlanFile = pkgs.writeText "livepatch-plan-actual.json" (
            builtins.toJSON qualificationActualPlan
          );
          qualificationActualCaptureFile = pkgs.writeText "livepatch-capture-actual.json" (
            builtins.toJSON qualificationActualCapture
          );
          qualificationActualNfsOracleFile = pkgs.writeText "livepatch-nfs-oracle-actual.rb" (
            qualificationActualNfsHelper.oracleScripts.operation-safety
          );
          qualificationActualExpectedAgingFile = pkgs.writeText "livepatch-aging-actual.json" (
            builtins.toJSON qualificationActualExpectedAgingBySet
          );
          qualificationNfsCompatibilityPlanFile = pkgs.writeText "livepatch-plan-nfs-compatibility.json" (
            builtins.toJSON qualificationNfsCompatibilityPlan
          );
          qualificationNfsCompatibilityCaptureFile = pkgs.writeText "livepatch-capture-nfs-compatibility.json" (
            builtins.toJSON qualificationNfsCompatibilityCapture
          );
          qualificationNfsCompatibilityOracleFile = pkgs.writeText "livepatch-nfs-oracle-compatibility.rb" (
            qualificationNfsCompatibilityHelper.oracleScripts.operation-safety
          );
          qualificationProfileConfigFile = pkgs.writeText "livepatch-profile-config.json" (
            builtins.toJSON {
              name = "kernel-livepatch-set-generic-lifecycle-amd";
              labels = {
                livepatch-profile = "set/vendor-lifecycle";
                livepatch-set = "6.12.113.1";
              };
              tags = [ "amd-livepatch" ];
            }
          );
          qualificationGenericValidator = pkgs.writeShellScript "validate-generic-livepatch-result" ''
            exec ${pkgs.bash}/bin/bash ${./tools/livepatch/validate-generic-result.sh} "$@"
          '';
          qualificationResultVerifier = pkgs.writeShellScript "verify-livepatch-result" ''
            exec ${pkgs.bash}/bin/bash ${./tools/livepatch/verify.sh} "$@"
          '';
          qualificationNfsValidator = pkgs.writeShellScript "validate-nfs-livepatch-result" ''
            exec ${pkgs.bash}/bin/bash ${./os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh} "$@"
          '';
        in
        {
          livepatch-qualification =
            assert qualificationPlanOne.counts.plannedMembers == 1;
            assert qualificationPlanOne.counts.matrixRows == 10;
            assert qualificationPlanOne.counts.coverageTuples == 2;
            assert qualificationPlanTwo.counts.plannedMembers == 2;
            assert qualificationPlanTwo.counts.matrixRows == 12;
            assert qualificationPlanTwo.counts.coverageTuples == 4;
            assert qualificationActualPlan.schemaVersion == 1;
            assert qualificationActualPlan.selectedSets == builtins.length qualificationActualSets;
            assert qualificationActualSets != [ ];
            assert qualificationActualPlan.counts.catalogReleases == builtins.length qualificationActualCatalog;
            assert qualificationActualSortedCatalogReleases == qualificationActualSortedPlannedReleases;
            assert qualificationActualPlannedReleases == qualificationActualMemberReleases;
            assert qualificationActualMemberReleases != [ ];
            assert builtins.all (
              set:
              let
                selectedReleases = map (unit: unit.batch.release) (qualificationActualSelectedCatalogForSet set);
                memberReleases = map (member: member.release) set.members;
              in
              selectedReleases != [ ]
              && selectedReleases == memberReleases
              && set.id == set.tipRelease
              && set.tipRelease == nixpkgs.lib.last memberReleases
              && builtins.all (member: member.kernelVersion == set.kernelVersion) set.members
            ) qualificationActualSets;
            assert
              qualificationActualPlan.counts.normalizedReleases
              == builtins.length qualificationActualPlan.releases;
            assert
              qualificationActualPlan.counts.plannedMembers == builtins.length qualificationActualMemberReleases;
            assert
              qualificationActualPlan.counts.activeOracles
              == builtins.length (builtins.concatLists (map (set: set.oracleIds) qualificationActualSets));
            assert
              qualificationActualPlan.counts.activeOracles
              == builtins.length (builtins.concatLists (map (set: set.oracles) qualificationActualSets));
            assert qualificationActualExpectedFixMembership == qualificationActualFixMembership;
            assert qualificationActualExpectedCoverageMembership == qualificationActualCoverageMembership;
            assert
              qualificationActualPlan.counts.coverageTuples == builtins.length qualificationActualPlan.coverage;
            assert
              qualificationActualPlan.counts.coverageTuples
              == builtins.length qualificationActualExpectedOraclePlatforms;
            assert
              qualificationActualPlan.counts.requiredProfilePlatformTuples
              == builtins.length qualificationActualSetRows;
            assert qualificationActualPlan.counts.plannedRows == builtins.length qualificationActualPlan.rows;
            assert
              qualificationActualPlan.counts.matrixRows == builtins.length qualificationActualPlan.matrix.include;
            assert
              qualificationActualPlan.counts.plannedRows
              == builtins.length qualificationActualSetRows + builtins.length qualificationActualFixRows;
            assert
              qualificationActualPlan.matrix.include == compactQualificationRows qualificationActualPlan.rows;
            assert qualificationActualCapture.selectedSets == qualificationActualPlan.selectedSets;
            assert builtins.length qualificationActualCaptureSets == builtins.length qualificationActualSets;
            assert
              map (set: set.id) qualificationActualCaptureSets == map (set: set.id) qualificationActualSets;
            assert
              qualificationActualCapture.counts.plannedMembers
              == builtins.length qualificationActualMemberReleases;
            assert
              qualificationActualCapture.counts.capturedMembers
              == builtins.length qualificationActualCapturedMembers;
            assert
              map (member: member.release) qualificationActualCapturedMembers
              == qualificationActualMemberReleases;
            assert builtins.all (
              member:
              builtins.attrNames member == [
                "audit"
                "identity"
                "release"
              ]
            ) qualificationActualCapturedMembers;
            assert builtins.all
              (
                field:
                builtins.length (
                  nixpkgs.lib.unique (map (member: member.identity.${field}) qualificationActualCapturedMembers)
                ) == builtins.length qualificationActualCapturedMembers
              )
              [
                "producer"
                "module"
                "moduleName"
                "moduleSha256"
                "inputDigest"
              ];
            assert builtins.all (
              captureSet:
              let
                planSet = builtins.head (builtins.filter (set: set.id == captureSet.id) qualificationActualSets);
              in
              builtins.all (
                member:
                member.identity.sourceRevision == qualificationActualPlan.sourceRevision
                && member.identity.flakeLockSha256 == qualificationActualCapture.flakeLockSha256
                && member.identity.targetId == "synthetic-target-${planSet.kernelVersion}"
                && member.identity.vermagic == "${planSet.kernelVersion} synthetic"
                && member.audit.deriver == "${member.identity.producer}.drv"
                && member.audit.requisites == [ member.identity.producer ]
              ) captureSet.members
            ) qualificationActualCaptureSets;
            assert qualificationEvaluationFails qualificationMissingProfile;
            assert qualificationEvaluationFails qualificationMissingAgedSettings;
            assert qualificationEvaluationFails qualificationPartialAgedSettings;
            assert qualificationEvaluationFails qualificationExtraAgedSettings;
            assert qualificationEvaluationFails qualificationUnknownAgedClass;
            assert qualificationEvaluationFails qualificationNonIntegerAgedSettings;
            assert qualificationEvaluationFails qualificationNonPositiveAgedSettings;
            assert qualificationEvaluationFails qualificationNonIncreasingAgedSettings;
            assert qualificationEvaluationFails qualificationMissingOracle;
            assert qualificationEvaluationFails qualificationDuplicateOracle;
            assert qualificationEvaluationFails qualificationAuthoredRunnerClass;
            assert qualificationEvaluationFails qualificationFlatOraclePath;
            assert qualificationEvaluationFails qualificationLeadingZeroOraclePath;
            assert qualificationEvaluationFails qualificationMissingPlatformRunner;
            assert qualificationEvaluationFails qualificationEmptyPlatformRunner;
            assert qualificationEvaluationFails qualificationWrongPlatformRunner;
            assert qualificationEvaluationFails qualificationUnknownApplicablePlatform;
            assert qualificationEvaluationFails qualificationAbsentApplicablePlatform;
            assert qualificationEvaluationFails qualificationDuplicateApplicablePlatform;
            assert builtins.length qualificationAgedRows == 2;
            assert builtins.all (
              row:
              row.aging == {
                checkpointSeconds = 60;
                developmentDwellSeconds = 300;
                dwellSeconds = 300;
                evidenceClass = "development-short";
                releaseDwellSeconds = 1800;
              }
            ) qualificationAgedRows;
            assert builtins.length qualificationReleaseAgedRows == 2;
            assert builtins.all (
              row:
              row.aging == {
                checkpointSeconds = 60;
                developmentDwellSeconds = 300;
                dwellSeconds = 1800;
                evidenceClass = "release";
                releaseDwellSeconds = 1800;
              }
            ) qualificationReleaseAgedRows;
            assert
              builtins.length qualificationActualAgedRows == builtins.length (
                builtins.concatLists (
                  map (
                    set: builtins.attrNames (qualificationActualTipForSet set).qualification.platforms
                  ) qualificationActualSets
                )
              );
            assert builtins.all (
              row: row.aging == qualificationActualExpectedAgingBySet.${row.setId}
            ) qualificationActualAgedRows;
            assert
              map (row: builtins.removeAttrs row [ "aging" ]) qualificationPlanOne.rows
              == map (row: builtins.removeAttrs row [ "aging" ]) qualificationReleaseSelection.rows;
            assert
              qualificationOracleRows == [
                {
                  expectedOutcome = "success";
                  fixId = "fix-a";
                  id = "oracle-a";
                  oracleIds = [ "oracle-a" ];
                  oracleShard = "oracle-a";
                  platform = {
                    id = "amd";
                    runnerClass = "amd-livepatch";
                    supported = true;
                  };
                  platformId = "amd";
                  platforms = [
                    "amd"
                    "intel"
                  ];
                  profileId = "fix/fix-a/oracle-a";
                  role = "fixed-path";
                  rowId = "6.12.113.1--fix-fix-a-oracle-a--amd";
                  runnerClass = "amd-livepatch";
                  scope = "fix";
                  setId = "6.12.113.1";
                  supported = true;
                  template = "kernel/livepatch-fix";
                  testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/fix-a.nix";
                  timeoutClass = "oracle";
                  validator = "os/livepatches/batches/6.12.113/1/qualification/validators/fix-a.sh";
                }
                {
                  expectedOutcome = "success";
                  fixId = "fix-a";
                  id = "oracle-a";
                  oracleIds = [ "oracle-a" ];
                  oracleShard = "oracle-a";
                  platform = {
                    id = "intel";
                    runnerClass = "intel-kvm";
                    supported = true;
                  };
                  platformId = "intel";
                  platforms = [
                    "amd"
                    "intel"
                  ];
                  profileId = "fix/fix-a/oracle-a";
                  role = "fixed-path";
                  rowId = "6.12.113.1--fix-fix-a-oracle-a--intel";
                  runnerClass = "intel-kvm";
                  scope = "fix";
                  setId = "6.12.113.1";
                  supported = true;
                  template = "kernel/livepatch-fix";
                  testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/fix-a.nix";
                  timeoutClass = "oracle";
                  validator = "os/livepatches/batches/6.12.113/1/qualification/validators/fix-a.sh";
                }
              ];
            assert
              builtins.elemAt qualificationUnsupportedOracleRows 0 == builtins.elemAt qualificationOracleRows 0;
            assert
              (builtins.elemAt qualificationUnsupportedOracleRows 1).platform == {
                id = "intel";
                runnerClass = "intel-kvm";
                supported = false;
                unsupportedReason = "Intel qualification runner unavailable";
              };
            assert (builtins.elemAt qualificationUnsupportedOracleRows 1).runnerClass == "intel-kvm";
            assert (builtins.elemAt qualificationUnsupportedOracleRows 1).supported == false;
            assert (builtins.elemAt qualificationUnsupportedOracleRows 1).expectedOutcome == "blocked";
            assert
              (builtins.elemAt qualificationUnsupportedOracleRows 1).unsupportedReason
              == "Intel qualification runner unavailable";
            assert qualificationPlanOne.matrix.include == compactQualificationRows qualificationPlanOne.rows;
            assert
              qualificationUnsupportedIntel.matrix.include
              == compactQualificationRows qualificationUnsupportedIntel.rows;
            pkgs.runCommand "livepatch-qualification-check"
              {
                livepatchCiTools = livepatchCiTools.${system};
                inherit stackManagerReceipt stackManagerUnit;
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.diffutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.jq
                ];
              }
              ''
                set -euo pipefail
                one=${qualificationPlanOneFile}
                two=${qualificationPlanTwoFile}
                actual=${qualificationActualPlanFile}

                test -e "$stackManagerUnit"
                jq -e '
                  .instance == "production-manager-private-stack"
                  and .name == "kernel-livepatch-production-manager-stack"
                  and .machines == ["boot_on", "machine", "switch_off", "switch_on"]
                  and .tags == ["ci"]
                ' "$stackManagerReceipt" > livepatch-stack-manager-render.log
                grep -F 'live-patches load 1' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'live-patches unload 3' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'module_param_cb(stack_value' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'loadOnSwitch = false;' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'kernelImage = switchKernelImage;' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'configured_modules = lambda do |guest|' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F '/run/booted-system/kernel-modules' ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F "switch_off.succeeds('live-patches load'" ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F "switch_off.succeeds('live-patches unload'" ${./tests/suite/kernel/livepatch-set/manager.nix}
                grep -F 'managerFixture = true;' ${./tests/all-tests.nix}
                if grep -E 'compatibility|nfs-livepatch|nfs-sysfs|batches/6[.]12[.]113' \
                  ${./tests/suite/kernel/livepatch-set.nix}; then
                  echo 'generic livepatch-set template contains release-specific fixture logic' >&2
                  exit 1
                fi

                ${pkgs.ruby}/bin/ruby ${qualificationSerializationCheck} \
                  ${qualificationOracleScriptFile} \
                  ${qualificationRootSetJsonFile} \
                  ${qualificationRootRowJsonFile} \
                  ${qualificationSuccessorSetJsonFile} \
                  ${qualificationFixRowJsonFile} \
                  ${qualificationOracleScriptMapJsonFile} \
                  > qualification-serialization.log
                grep -F 'rubyJson = import ./livepatch-ruby-json.nix' ${./tests/suite/kernel/livepatch-set.nix}
                grep -F 'rubyJson = import ./livepatch-ruby-json.nix' ${./tests/suite/kernel/livepatch-fix.nix}
                grep -F 'VPSADMINOS_LIVEPATCH_JSON_END' ${./tests/suite/kernel/livepatch-ruby-json.nix}
                grep -F 'assert !lib.hasInfix' ${./tests/suite/kernel/livepatch-ruby-json.nix}
                grep -F "JSON.parse(<<~'" ${./tests/suite/kernel/livepatch-ruby-json.nix}
                if grep -F 'builtins.toJSON' \
                  ${./tests/suite/kernel/livepatch-set.nix} \
                  ${./tests/suite/kernel/livepatch-fix.nix}; then
                  echo 'production template bypasses the shared Ruby JSON carrier' >&2
                  exit 1
                fi

                jq -e '
                  .selectedSets == 1
                  and (.sets[0].members | length) == 1
                  and ([.matrix.include[].runnerClass] | unique | sort) == ["amd-livepatch", "intel-kvm"]
                  and ([.rows[] | select(.scope == "set") | .role] | unique | sort) == ["aged-transition", "busy-transition", "failure-recovery", "lifecycle"]
                  and ([.rows[] | select(.role == "aged-transition")] | length) == 2
                  and ([.rows[] | select(.role == "aged-transition") | .aging.evidenceClass] | unique) == ["development-short"]
                  and ([.rows[] | select(.role == "aged-transition") | .aging.dwellSeconds] | unique) == [300]
                  and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
                  and ([.rows[] | select(.scope == "set") | .oracleShard] | all(. == "none"))
                  and ([.rows[] | select(.scope == "set") | .validator] | all(. == "builtin/generic-livepatch-safety-v1"))
                  and (.coverage | length) == 2
                ' "$one" >/dev/null

                jq -e --slurpfile expectedAging ${qualificationActualExpectedAgingFile} '
                  . as $plan
                  | [$plan.rows[] | select(.scope == "set")] as $setRows
                  | [$plan.rows[] | select(.scope == "fix")] as $fixRows
                  | [
                      $plan.sets[] as $set
                      | $set.oracles[] as $oracle
                      | $oracle.platforms[] as $platformId
                      | {setId: $set.id, fixId: $oracle.fixId, oracleId: $oracle.id, $platformId}
                    ] as $expectedFixMembership
                  | .schemaVersion == 1
                  and .selectedSets == ($plan.sets | length)
                  and (.sets | length) > 0
                  and .counts.catalogReleases == ($plan.releases | length)
                  and .counts.normalizedReleases == ($plan.releases | length)
                  and .counts.plannedMembers == ([$plan.sets[].members[]] | length)
                  and .counts.requiredProfilePlatformTuples == ($setRows | length)
                  and .counts.activeOracles == ([$plan.sets[].oracleIds[]] | length)
                  and .counts.activeOracles == ([$plan.sets[].oracles[]] | length)
                  and .counts.coverageTuples == ($plan.coverage | length)
                  and .counts.coverageTuples == ($expectedFixMembership | length)
                  and .counts.plannedRows == ($plan.rows | length)
                  and .counts.plannedRows == (($setRows | length) + ($fixRows | length))
                  and .counts.matrixRows == ($plan.matrix.include | length)
                  and .counts.plannedRows == .counts.matrixRows
                  and ([$plan.releases[].release]) == ([$plan.sets[].members[].release])
                  and ([$plan.sets[] as $set
                    | ($set.members | length) > 0
                      and $set.id == $set.tipRelease
                      and $set.tipRelease == $set.members[-1].release
                      and ([range(0; ($set.members | length)) as $index
                        | $set.members[$index].kernelVersion == $set.kernelVersion
                          and $set.members[$index].releaseOrdinal == ($index + 1)
                          and $set.members[$index].predecessorRelease
                            == (if $index == 0 then null else $set.members[$index - 1].release end)
                      ] | all)
                  ] | all)
                  and ([$plan.sets[] as $set
                    | ([$setRows[] | select(.setId == $set.id) | .role] | unique | sort)
                      == ["aged-transition", "busy-transition", "failure-recovery", "lifecycle"]
                  ] | all)
                  and ($setRows | all(
                    .oracleIds == []
                    and .oracleShard == "none"
                    and .validator == "builtin/generic-livepatch-safety-v1"
                  ))
                  and ($fixRows | map({setId, fixId, oracleId: .id, platformId})
                    | sort_by([.setId, .fixId, .oracleId, .platformId]))
                    == ($expectedFixMembership | sort_by([.setId, .fixId, .oracleId, .platformId]))
                  and ($fixRows | all(. as $row | $row.oracleIds == [$row.id]))
                  and ($plan.coverage | sort_by(.rowId)) == ($fixRows | map({
                    oracleId: .id,
                    platformId,
                    profileId,
                    rowId,
                    setId
                  }) | sort_by(.rowId))
                  and $plan.matrix.include == ($plan.rows | map({
                    expectedOutcome,
                    profileId,
                    rowId,
                    runnerClass,
                    setId,
                    timeoutClass
                  }))
                  and ([$plan.sets[] as $set
                    | ([$setRows[] | select(.setId == $set.id and .role == "aged-transition")] | length)
                      == ([$setRows[] | select(.setId == $set.id) | .platform.id] | unique | length)
                  ] | all)
                  and ([$plan.rows[] | select(.role == "aged-transition")]
                    | all(. as $row | $row.aging == $expectedAging[0][$row.setId]))
                  and ($expectedAging[0] | keys | sort) == ([$plan.sets[].id] | sort)
                  and ($expectedAging[0] | to_entries | map(.value) | all(
                    (keys | sort) == [
                      "checkpointSeconds", "developmentDwellSeconds", "dwellSeconds",
                      "evidenceClass", "releaseDwellSeconds"
                    ]
                    and (.checkpointSeconds | type == "number" and floor == . and . > 0)
                    and (.developmentDwellSeconds | type == "number" and floor == . and . > 0)
                    and (.releaseDwellSeconds | type == "number" and floor == . and . > 0)
                    and .developmentDwellSeconds < .releaseDwellSeconds
                    and (.evidenceClass == "development-short" or .evidenceClass == "release")
                    and .dwellSeconds == (
                      if .evidenceClass == "development-short" then
                        .developmentDwellSeconds
                      else
                        .releaseDwellSeconds
                      end
                    )
                  ))
                ' "$actual" >/dev/null

                jq -e '
                  .selectedSets == 1
                  and (.sets[0].members | map(.release)) == ["6.12.113.1", "6.12.113.2"]
                  and .sets[0].members[1].predecessorRelease == "6.12.113.1"
                  and .counts.plannedMembers == 2
                  and .counts.matrixRows == 12
                  and .counts.coverageTuples == 4
                  and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
                  and ([.coverage[] | .oracleId] | sort) == ["oracle-a", "oracle-a", "oracle-b", "oracle-b"]
                ' "$two" >/dev/null

                grep -F 'rawBuildLogIdentity: "per-realization-only"' ${./tools/livepatch/capture.sh}
                grep -F 'def canonical_callbacks: sort_by([.kind, .object, .symbol]);' ${./tools/livepatch/capture.sh}
                grep -F '.audit.buildLogSha256' ${./tools/livepatch/verify.sh}

                jq -n '{
                  callbacks: [
                    {kind: "pre_patch", object: "vmlinux", symbol: "level_pre"},
                    {kind: "post_patch", object: "vmlinux", symbol: "level_post"},
                    {kind: "post_unpatch", object: "vmlinux", symbol: "level_unpost"}
                  ]
                }' > callbacks-expected.json
                jq '.callbacks |= reverse' callbacks-expected.json > callbacks-reordered.json
                jq '.callbacks |= .[1:]' callbacks-expected.json > callbacks-missing.json
                jq '.callbacks += [{kind: "pre_unpatch", object: "vmlinux", symbol: "level_unpre"}]' \
                  callbacks-expected.json > callbacks-extra.json
                jq '.callbacks[0].symbol = "level_changed"' \
                  callbacks-expected.json > callbacks-changed.json
                jq '.callbacks += [.callbacks[0]]' callbacks-expected.json > callbacks-duplicate.json

                callbacks_match() {
                  jq -e --slurpfile expected callbacks-expected.json '
                    def canonical_callbacks: sort_by([.kind, .object, .symbol]);

                    (.callbacks | canonical_callbacks)
                      == ($expected[0].callbacks | canonical_callbacks)
                  ' "$1" >/dev/null
                }

                callbacks_match callbacks-reordered.json
                for invalid in callbacks-missing.json callbacks-extra.json \
                  callbacks-changed.json callbacks-duplicate.json; do
                  if callbacks_match "$invalid"; then
                    echo "invalid callback inventory accepted: $invalid" >&2
                    exit 1
                  fi
                done

                ${pkgs.bash}/bin/bash ${./tools/livepatch/tests/generic-safety-hypervisor.sh} \
                  ${./tests/suite/kernel/livepatch-set.nix} \
                  > generic-safety-hypervisor.log

                ${pkgs.bash}/bin/bash ${./tools/livepatch/tests/generic-safety.sh} \
                  ${qualificationGenericValidator} \
                  ${qualificationResultVerifier} \
                  ${pkgs.ruby}/bin/ruby \
                  ${./tests/suite/kernel/livepatch-set.nix} \
                  ${qualificationNfsValidator} \
                  ${qualificationNfsCompatibilityOracleFile} \
                  ${qualificationNfsCompatibilityPlanFile} \
                  ${qualificationNfsCompatibilityCaptureFile} \
                  ${pkgs.python3}/bin/python3 \
                  ${./tests/suite/kernel/livepatch-set/workload.nix} \
                  ${qualificationWorkloadPackage}/bin/livepatch-generic-workload \
                  ${./tools/livepatch/run-profile.sh} \
                  ${qualificationProfileConfigFile} \
                  > generic-safety.log

                PYTHONPYCACHEPREFIX="$PWD/python-cache" \
                  ${pkgs.python3}/bin/python3 -m py_compile \
                  ${qualificationWorkloadPackage}/bin/livepatch-generic-workload
                grep -Fx 'generic workload initialization matrix passed' \
                  generic-safety.log > workload-init.log
                grep -Fx 'generic workload CLI exit matrix passed' \
                  generic-safety.log > workload-cli.log
                sha256sum ${qualificationWorkloadPackage}/bin/livepatch-generic-workload \
                  > workload-generated.sha256

                ${pkgs.bash}/bin/bash ${./tools/livepatch/tests/verify-capture.sh} \
                  ${pkgs.bash}/bin/bash \
                  ${qualificationResultVerifier} \
                  ${./tools/livepatch/capture.sh} \
                  ${./tools/livepatch/run-profile.sh} \
                  ${./tools/livepatch/ci-workspace.sh} \
                  ${./.github/workflows/livepatch.yml} \
                  > verify-capture.log

                ${pkgs.bash}/bin/bash ${./tools/livepatch/tests/ci-tool-closure.sh} \
                  ${./.} "$livepatchCiTools" > ci-tool-closure.log

                mkdir "$out"
                printf '%s\n' "$livepatchCiTools" > "$out/livepatch-ci-tools-path.txt"
                printf '%s\n' ${qualificationProfileConfigFile} > "$out/livepatch-profile-config-path.txt"
                cp "$one" "$out/plan-one.json"
                cp "$two" "$out/plan-two.json"
                cp ${qualificationActualPlanFile} "$out/plan-actual.json"
                cp ${qualificationActualCaptureFile} "$out/capture-actual.json"
                cp ${qualificationActualNfsOracleFile} "$out/nfs-oracle-actual.rb"
                cp qualification-serialization.log "$out/qualification-serialization.log"
                cp generic-safety-hypervisor.log "$out/generic-safety-hypervisor.log"
                cp generic-safety.log "$out/generic-safety.log"
                cp workload-init.log "$out/workload-init.log"
                cp workload-cli.log "$out/workload-cli.log"
                cp workload-generated.sha256 "$out/workload-generated.sha256"
                cp verify-capture.log "$out/verify-capture.log"
                cp ci-tool-closure.log "$out/ci-tool-closure.log"
              '';
          qemu-disk-lifecycle = import ./tests/qemu-disk-lifecycle-check.nix {
            inherit pkgs;
            makeSystem = args: vpsadminosSystem (args // { inherit system; });
          };
          nixos-disk-image-reuse = import ./tests/nixos-disk-image-reuse-check.nix {
            inherit nixpkgs system testFramework;
          };
          nixos-container-persistence = import ./tests/nixos-container-persistence-check.nix {
            pkgs = import nixpkgs { inherit system; };
            source = self.outPath;
            inherit
              system
              nixpkgs
              nixpkgsUnstable
              impermanence
              ;
          };
          os-eval = sys.config.system.build.toplevel;
          vpsadminos-disk-image-reuse = import ./tests/vpsadminos-disk-image-reuse-check.nix {
            inherit nixpkgs system testFramework;
          };
          zfs-package-parity = import ./tests/zfs-package-parity-check.nix {
            pkgs = import nixpkgs { inherit system; };
            makeSystem = args: vpsadminosSystem (args // { inherit system; });
          };
        }
      );
    };
}
