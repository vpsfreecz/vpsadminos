let
  pkgs = import <nixpkgs> {
    overlays = [
      (import ./os/overlays/lxc.nix)
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
    ruby
  ];

  shellHook = ''
    export GEM_HOME="$(pwd)/.gems"
    export PATH="$(ruby -e 'puts Gem.bindir'):$PATH"
    export RUBYLIB="$GEM_HOME"
    gem install --no-document bundler geminabox
    [ -f shellhook.local.sh ] && . shellhook.local.sh
  '';
}
