{
  forAllSystems,
  nixpkgs,
  root,
  testFramework,
}:
{
  tests = forAllSystems (
    system:
    let
      allTests = import (root + "/tests/all-tests.nix") {
        pkgs = nixpkgs.outPath;
        inherit system;
        suiteArgs = { };
        testConfig = { };
        configuration = null;
        inherit testFramework;
      };
    in
    builtins.mapAttrs (_: t: t.test.json) allTests
  );

  testsMeta = forAllSystems (
    system:
    let
      pkgsPath = nixpkgs.outPath;
      nixpkgs' = import pkgsPath { inherit system; };
      lib' = nixpkgs'.lib;

      testLib = testFramework.makeTestLib {
        pkgs = pkgsPath;
        inherit system;
        lib = lib';
        suitePath = (root + "/tests/suite");
        suiteArgs = { };
        testConfig = { };
        configuration = null;
      };

      allTests = import (root + "/tests/all-tests.nix") {
        pkgs = pkgsPath;
        inherit system;
        suiteArgs = { };
        testConfig = { };
        configuration = null;
        inherit testFramework;
      };
    in
    testLib.metaFromAllTests allTests
  );

}
