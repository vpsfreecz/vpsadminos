{
  description = "vpsAdminOS flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.nixpkgsUnstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.impermanence.url = "github:nix-community/impermanence";

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
      kernelVersions =
        builtins.attrNames (import ./os/packages/linux/available-kernels.nix { lib = nixpkgs.lib; }).kernels;
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
      vpsadminosGithubRev =
        if self ? rev then
          self.rev
        else if self ? dirtyRev then
          builtins.substring 0 40 self.dirtyRev
        else
          null;
      containerStableModule = import ./os/lib/nixos-container/stable/vpsadminos.nix;
      containerStable2211Module = import ./os/lib/nixos-container/stable/vpsadminos-22.11.nix;
      containerStable2305Module = import ./os/lib/nixos-container/stable/vpsadminos-23.05.nix;
      containerStable2311Module = import ./os/lib/nixos-container/stable/vpsadminos-23.11.nix;
      containerStable2405Module = import ./os/lib/nixos-container/stable/vpsadminos-24.05.nix;
      containerStable2411Module = import ./os/lib/nixos-container/stable/vpsadminos-24.11.nix;
      containerStable2505Module = import ./os/lib/nixos-container/stable/vpsadminos-25.05.nix;
      containerStable2511Module = import ./os/lib/nixos-container/stable/vpsadminos-25.11.nix;
      containerUnstableModule = import ./os/lib/nixos-container/unstable/vpsadminos.nix;
      kernelDevToplevelModule =
        { config, ... }:
        {
          system.systemBuilderCommands = ''
            ln -sf ${config.boot.kernelPackage.dev} $out/kernel-dev
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
          flakeRev = self.rev or (self.dirtyRev or null);
          flakeShortRev =
            self.shortRev or (
              if self ? dirtyShortRev then
                self.dirtyShortRev
              else if flakeRev == null then
                null
              else
                builtins.substring 0 7 flakeRev
            );
          flakeVersionInfoModule =
            { lib, ... }:
            {
              system.vpsadminos = lib.optionalAttrs (flakeRev != null) (
                {
                  revision = lib.mkDefault flakeRev;
                }
                // lib.optionalAttrs (flakeShortRev != null) {
                  versionSuffix = lib.mkDefault ".git.${flakeShortRev}";
                }
              );
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
            modules = modules ++ [ flakeVersionInfoModule ];
            extraArgs = specialArgs;
          }
          // nixpkgs.lib.optionalAttrs (configuration != null) { inherit configuration; }
        );
    in
    {
      lib.vpsadminosSystem = vpsadminosSystem;
      lib.testFramework = {
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

            testLib = import (self.outPath + "/test-runner/nix/lib.nix") {
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
            };
          in
          testLib.metaFromAllTests allTests;
      };
      nixpkgsPath = nixpkgs.outPath;

      nixosModules = {
        vpsadminos =
          { pkgs, ... }:
          {
            imports = import ./os/modules/module-list.nix { nixpkgsPath = pkgs.path; };
          };

        container = containerStableModule;
        containerStable = containerStableModule;
        container_22_11 = containerStable2211Module;
        container_23_05 = containerStable2305Module;
        container_23_11 = containerStable2311Module;
        container_24_05 = containerStable2405Module;
        container_24_11 = containerStable2411Module;
        container_25_05 = containerStable2505Module;
        container_25_11 = containerStable2511Module;
        containerUnstable = containerUnstableModule;
      };

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

          testLib = import ./test-runner/nix/lib.nix {
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
          };
        in
        testLib.metaFromAllTests allTests
      );

      packages = forAllSystems (
        system:
        let
          pkgsBase = nixpkgs.legacyPackages.${system};
          overlays = import ./os/overlays;
          pkgsWithOverlays = pkgsBase.extend (nixpkgs.lib.composeManyExtensions overlays);

          mkQemuSystem =
            extraModules:
            vpsadminosSystem {
              inherit system;
              modules = [ ./os/configs/qemu.nix ] ++ extraModules;
            };

          qemuSystem = mkQemuSystem [ ];
          proactiveSwapQemuSystem = mkQemuSystem [ ./os/configs/proactive-swap-qemu.nix ];
          ciQemuSystem = mkQemuSystem [ kernelDevToplevelModule ];

          kernelCiQemuSystems = builtins.listToAttrs (
            map (kernelVersion: {
              name = ciKernelOutputName kernelVersion;
              value = mkQemuSystem [
                kernelDevToplevelModule
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
            qemu = qemuSystem.config.system.build.runvm;
            qemu-proactive-swap = proactiveSwapQemuSystem.config.system.build.runvm;
            toplevel = qemuSystem.config.system.build.toplevel;
            ci-toplevel = ciQemuSystem.config.system.build.toplevel;
            qemu-script = qemuSystem.config.system.build.runvmScript;
            qemu-script-proactive-swap = proactiveSwapQemuSystem.config.system.build.runvmScript;
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
            test-runner = import ./test-runner/nix/package.nix {
              pkgs = pkgsWithOverlays;
            };
          }
          // ciKernelToplevelPackages
        )
      );

      devShells = forAllSystems (
        system:
        let
          pkgsBase = nixpkgs.legacyPackages.${system};
          lib = pkgsBase.lib;
          overlays = import ./os/overlays;
          pkgs = pkgsBase.extend (lib.composeManyExtensions overlays);

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
              nixfmt-rfc-style
              nixfmt-tree
              ruby_vpsadminos
            ];
            shellHook = ''
              # Work around TMPDIR not being set correctly in development shells
              export TMPDIR=/tmp

              export GEM_HOME="$(pwd)/.gems"
              export PATH="$(ruby -e 'puts Gem.bindir'):$PATH"
              export RUBYLIB="$GEM_HOME"
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
              go
              gotools
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
              ruby
              zlib
            ];
            shellHook = ''
              REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
              TEST_RUNNER_ROOT="$REPO_ROOT/test-runner"
              GEM_HOME="$TEST_RUNNER_ROOT/.gems"

              export REPO_ROOT
              export TEST_RUNNER_ROOT
              export GEM_HOME
              export GEM_PATH="$GEM_HOME:$TEST_RUNNER_ROOT/lib"
              export PATH="$GEM_HOME/bin:$PATH"

              mkdir -p "$GEM_HOME"

              BUNDLE="$GEM_HOME/bin/bundle"

              if [ ! -x "$BUNDLE" ]; then
                ${pkgs.ruby}/bin/gem install bundler --no-document
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
