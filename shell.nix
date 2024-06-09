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

    # TODO: remove when geminabox is fixed, see https://github.com/geminabox/geminabox/pull/572
    gem install --no-document rubygems-generate_index

    [ -f shellhook.local.sh ] && . shellhook.local.sh
  '';
}
