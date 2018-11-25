let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "vpsadminos";

  buildInputs = with pkgs; [
    git
    gnumake
    mkdocs
    ruby
  ];

  shellHook = ''
    export PATH="$PATH:$(ruby -e 'puts Gem.bindir')"
    gem install --no-ri geminabox md2man rake rake-compiler yard
  '';
}
