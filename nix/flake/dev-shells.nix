{
  forAllSystems,
  inputs,
  nixpkgs,
  osOverlays,
  root,
}:
{
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
          python3
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

}
