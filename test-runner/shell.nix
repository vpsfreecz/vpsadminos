let
  pkgs = import <nixpkgs> { overlays = (import ../os/overlays); };
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "test-runner";

  buildInputs = [
    pkgs.ruby
    pkgs.git
    pkgs.zlib
  ];

  shellHook = ''
    mkdir -p .gems
    export GEM_HOME="`pwd`/.gems"
    export GEM_PATH="$GEM_HOME:$PWD/lib"
    export PATH="$GEM_HOME/bin:$PATH"

    BUNDLE="$GEM_HOME/bin/bundle"

    [ ! -x "$BUNDLE" ] && ${pkgs.ruby}/bin/gem install bundler

    export BUNDLE_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE="$PWD/Gemfile"

    $BUNDLE install

    export RUBYOPT=-rbundler/setup
  '';
}
