{ batchLib }:

let
  unit = import ../../../catalog/6.12.113/1/default.nix { inherit batchLib; };
in
unit
// {
  batch = unit.batch // {
    release = "6.12.113.2";
  };
}
