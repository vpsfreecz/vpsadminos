let
  pkgs = import <nixpkgs> { overlays = (import ../os/overlays); };
  lib = pkgs.lib;
  stdenv = pkgs.stdenv;

  path = with pkgs; [
    apparmor-parser
    coreutils
    iproute
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
    bpftool
  ];

  pathJoined = lib.concatMapStringsSep ":" (s: "${s}/bin") path;

  apparmorPaths = [ pkgs.apparmor-profiles ];

  osctldConfig = {
    debug = true;

    apparmor_paths = map (s: "${s}/etc/apparmor.d") apparmorPaths;

    ctstartmenu = "${pkgs.ctstartmenu}/bin/ctstartmenu";

    lock_registry = true;

    cpu_scheduler = {
      enable = true;
    };
  };

  jsonConfigFile = pkgs.writeText "osctld-config.json" (builtins.toJSON osctldConfig);

in stdenv.mkDerivation rec {
  name = "osctld";

  buildInputs = [
    pkgs.ruby
    pkgs.git
    pkgs.lxc
    pkgs.zlib
    pkgs.openssl
  ];

  shellHook = ''
    mkdir -p /tmp/dev-ruby-gems
    export GEM_HOME="/tmp/dev-ruby-gems"
    export GEM_PATH="$GEM_HOME:$PWD/lib"
    export PATH="$GEM_HOME/bin:$PATH:${pathJoined}"

    BUNDLE="$GEM_HOME/bin/bundle"

    [ ! -x "$BUNDLE" ] && ${pkgs.ruby}/bin/gem install bundler

    export BUNDLE_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE="$PWD/Gemfile"

    $BUNDLE install

    export RUBYOPT=-rbundler/setup

    run-osctld() {
      bundle exec bin/osctld --config ${jsonConfigFile}
    }

    run-memory-profiler-osctld() {
      bundle exec $GEM_HOME/ruby/*/bin/ruby-memory-profiler bin/osctld -- --no-supervisor --config ${jsonConfigFile}
    }
  '';
}
