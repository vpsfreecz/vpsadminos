{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  testsRoot ? ./tests,
}:
let
  nixpkgs = import pkgs { };
  lib = nixpkgs.lib;
  testLib = import ./lib.nix {
    inherit pkgs system lib;
    suitePath = testsRoot + "/suite";
  };

  allTests = import (testsRoot + "/all-tests.nix") { inherit pkgs system; };
in
testLib.metaFromAllTests allTests
