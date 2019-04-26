{ nixpkgs ? import <nixpkgs> {}, compiler ? "ghc864" }:
nixpkgs.haskell.lib.overrideCabal
  (nixpkgs.haskell.packages.${compiler}.callPackage ./pty-wrapper.nix { })
  ( oldDrv: {
      isLibrary = false;
      enableSharedExecutables = false;
      enableSharedLibraries = false;
    }
  )
