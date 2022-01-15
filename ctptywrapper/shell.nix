let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "ctstartmenu";

  buildInputs = with pkgs;[
    git
    go
    gotools
  ];
}
