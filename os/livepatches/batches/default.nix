{ lib }:

let
  batchLib = import ../lib.nix { inherit lib; };
in
batchLib.discoverCatalog ./.
