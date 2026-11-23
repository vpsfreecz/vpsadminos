# Discover typed source owners, never regular files or symlinks in place of owners.
{ lib }:
root: namePattern: load:
let
  entries = if builtins.pathExists root then builtins.readDir root else { };
in
lib.mapAttrs (
  name: type:
  let
    dir = root + "/${name}";
    records = builtins.readDir dir;
  in
  assert lib.assertMsg (
    type == "directory" && builtins.match namePattern name != null
  ) "Invalid release payload owner ${toString dir}";
  assert lib.assertMsg (
    (records."default.nix" or null) == "regular"
  ) "Missing ownership record ${toString dir}/default.nix";
  load name dir records
) entries
