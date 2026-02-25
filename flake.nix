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
              # Workaround for broken TMPDIR in nix-shell
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
