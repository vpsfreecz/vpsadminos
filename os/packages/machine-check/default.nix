{ nixpkgs ? import <nixpkgs> {}, compiler ? "ghc864" }:
let
  data-prometheus = nixpkgs.haskell.packages.${compiler}.callPackage ./data-prometheus.nix { };
in
  nixpkgs.haskell.lib.overrideCabal
    ( nixpkgs.haskell.packages.${compiler}.callPackage ./machine-check.nix {
        inherit data-prometheus;
      }
    )
    ( oldDrv: {
        isLibrary = false;
        enableSharedExecutables = false;
        enableSharedLibraries = false;
      }
    )
