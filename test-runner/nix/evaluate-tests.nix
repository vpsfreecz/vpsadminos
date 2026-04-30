{
  repoRoot,
  system ? "x86_64-linux",
  testConfigPath ? null,
  mode ? "testsMetaAll",
  testPath ? null,
}:
let
  flake = builtins.getFlake (builtins.toString repoRoot);
  haveTestFramework =
    flake ? lib
    && flake.lib ? testFramework
    && flake.lib.testFramework ? mkTests
    && flake.lib.testFramework ? mkTestsMeta;

  testFramework =
    if testConfigPath == null then
      null
    else if haveTestFramework then
      flake.lib.testFramework
    else
      builtins.throw ''
        The tested repository does not export flake.lib.testFramework.mkTests
        and flake.lib.testFramework.mkTestsMeta, which are required when using
        --test-config. Repositories that do not use --test-config only need to
        export flake.tests and flake.testsMeta.
      '';

  testConfig = if testConfigPath == null then null else import testConfigPath;
  effectiveTestConfig = if testConfig == null then { } else testConfig;
  testsRoot = repoRoot + "/tests";
  directSingleTestAvailable =
    testPath != null && builtins.pathExists (testsRoot + "/suite/${testPath}.nix");

  directTestLib =
    let
      pkgsPath =
        if builtins.pathExists (repoRoot + "/nixpkgs") then
          repoRoot + "/nixpkgs"
        else
          <nixpkgs>;
      nixpkgs' = import pkgsPath { inherit system; };
    in
    import (repoRoot + "/test-runner/nix/lib.nix") {
      pkgs = pkgsPath;
      inherit system;
      lib = nixpkgs'.lib;
      suitePath = testsRoot + "/suite";
      configuration = null;
      testConfig = effectiveTestConfig;
    };

  directTest =
    (directTestLib.makeSingleTest {
      test = testPath;
      args = { };
    }).value;

  tests =
    if testConfigPath == null then
      flake.tests.${system}
    else
      testFramework.mkTests {
        inherit system testConfig;
        testsRoot = repoRoot + "/tests";
        configuration = null;
      };

  testsMeta =
    if testConfigPath == null then
      flake.testsMeta.${system}
    else
      testFramework.mkTestsMeta {
        inherit system testConfig;
        testsRoot = repoRoot + "/tests";
        configuration = null;
      };
in
if mode == "testsMetaAll" then
  testsMeta
else if mode == "testsMetaOne" then
  if directSingleTestAvailable then
    directTestLib.testMeta directTest
  else
    builtins.getAttr testPath testsMeta
else if mode == "testJson" then
  if directSingleTestAvailable then
    directTest.test.json
  else
    builtins.getAttr testPath tests
else
  builtins.throw "Unsupported mode '${mode}'"
