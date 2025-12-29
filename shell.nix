let
  pkgs = import <nixpkgs> {
    overlays = [
      (import ./os/overlays/packages.nix)
      (import ./os/overlays/ruby.nix)
    ];
  };
  stdenv = pkgs.stdenv;
in
stdenv.mkDerivation rec {
  name = "vpsadminos";

  buildInputs = with pkgs; [
    bundix
    git
    gnumake
    libffi
    lxc
    mkdocs
    ncurses
    nixfmt-rfc-style
    nixfmt-tree
    ruby_3_4
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
  '';
}
