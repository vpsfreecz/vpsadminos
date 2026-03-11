{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  testsRoot ? ./tests,
  configuration ? null,
  testConfig ? { },
}:
let
  nixpkgs = import pkgs { };
  lib = nixpkgs.lib;
  testLib = import ./lib.nix {
    inherit
      pkgs
      system
      lib
      configuration
      testConfig
      ;
    suitePath = testsRoot + "/suite";
  };

  allTests = import (testsRoot + "/all-tests.nix") {
    inherit
      pkgs
      system
      configuration
      testConfig
      ;
  };
in
testLib.metaFromAllTests allTests
