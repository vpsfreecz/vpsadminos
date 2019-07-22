let
  pkgs = import <nixpkgs> { overlays = (import ../os/overlays/common.nix); };
  lib = pkgs.lib;
  stdenv = pkgs.stdenv;
  path = with pkgs; [
    apparmor-parser
    coreutils
    iproute
    glibc.bin
    gzip
    lxc
    nettools
    gnutar
    openssh
    pty-wrapper
    shadow
    utillinux
    zfs
  ];
  pathJoined = lib.concatMapStringsSep ":" (s: "${s}/bin") path;
  apparmorPaths = [ pkgs.apparmor-profiles ];
  apparmorPathsJoined = lib.concatMapStringsSep ":" (s: "${s}/etc/apparmor.d") apparmorPaths;

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

    export OSCTLD_APPARMOR_PATHS="${apparmorPathsJoined}"
  '';
}
