{ lib }:
(import ../../livepatches/owned-records.nix { inherit lib; }) ./kernel-specific
  "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"
  (
    _name: dir: files:
    let
      record = import dir;
      paths = map (patch: patch.patch) (record.kernelPatches or [ ]) ++ (record.postConfigPatches or [ ]);
      localSource =
        path:
        let
          name = builtins.baseNameOf path;
        in
        (files.${name} or null) == "regular" && path == dir + "/${name}";
    in
    assert lib.assertMsg (
      paths != [ ] && lib.all localSource paths
    ) "Invalid private kernel patch source under ${toString dir}";
    record
  )
