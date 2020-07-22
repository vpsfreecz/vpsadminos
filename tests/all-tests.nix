{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem
}:
let
  test = name: import (./suite + "/${name}.nix") { inherit pkgs system; };

  tests = list: builtins.listToAttrs (map (v: {
    name = v;
    value = test v;
  }) list);
in tests [
  "boot"
  "docker-ubuntu-20.04"
  "driver"
  "zfs-xattr"
]
