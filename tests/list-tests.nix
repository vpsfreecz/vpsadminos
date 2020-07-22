let
  nixpkgs = import <nixpkgs> {};

  allTests = import ./all-tests.nix {};

  meta = nixpkgs.lib.mapAttrs (k: v: {
    inherit (v.config) name description;
  }) allTests;
in meta
