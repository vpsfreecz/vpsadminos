let
  pkgs = import <nixpkgs> {
    overlays = [ (import ../../overlays/ruby.nix) ];
  };
in pkgs.callPackage ./default.nix {}
