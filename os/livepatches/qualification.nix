{ lib }:

let
  livepatchLib = import ./lib.nix { inherit lib; };
in
{
  builder,
  catalog ? import ./batches/default.nix { inherit lib; },
  target,
}:
let
  releases = livepatchLib.normalizeCatalog {
    inherit builder catalog target;
  };
in
{
  schemaVersion = 1;
  selectedSets = if releases == [ ] then 0 else 1;
  inherit releases;
}
