let
  pkgs = import <nixpkgs> {
    overlays = [
      (import ./os/overlays/packages.nix)
      (import ./os/overlays/ruby.nix)
    ];
  };
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "vpsadminos";

  buildInputs = with pkgs; [
    bundix
    git
    gnumake
    lxc
    mkdocs
    ncurses
    ruby_3_2
  ];

  shellHook = ''
    export GEM_HOME="$(pwd)/.gems"
    export PATH="$(ruby -e 'puts Gem.bindir'):$PATH"
    export RUBYLIB="$GEM_HOME"
    gem install --no-document bundler geminabox overcommit rubocop rubocop-rake
    [ -f shellhook.local.sh ] && . shellhook.local.sh
  '';
}
