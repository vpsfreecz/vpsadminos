{ lib }:
let
  directory = ./catalog;
  records = builtins.readDir directory;
  loadRecord =
    file:
    let
      match = builtins.match "((0|[1-9][0-9]*)([.](0|[1-9][0-9]*)){2})[.]nix" file;
    in
    if match == null || records.${file} != "regular" then
      throw "Invalid kernel catalog record: ${file} (expected a regular X.Y.Z.nix file)"
    else
      {
        name = builtins.head match;
        value = import (directory + "/${file}") { inherit lib; };
      };
in
{
  stableKernelVersion = "6.12.118";
  unstableKernelVersion = "6.18.49";
  kernels = builtins.listToAttrs (map loadRecord (builtins.attrNames records));
}
