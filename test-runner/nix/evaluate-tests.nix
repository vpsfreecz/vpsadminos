{
  repoRoot,
  system ? "x86_64-linux",
  testConfigPath ? null,
  mode ? "testsMetaAll",
  testPath ? null,
  testArgsJson ? null,
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
  directTestArgs = if testArgsJson == null then { } else builtins.fromJSON testArgsJson;

  directTestLib =
    let
      flakeNixpkgsPath =
        if flake ? inputs && flake.inputs ? nixpkgs && flake.inputs.nixpkgs ? outPath then
          flake.inputs.nixpkgs.outPath
        else
          null;
      pkgsPath =
        if builtins.pathExists (repoRoot + "/nixpkgs") then
          repoRoot + "/nixpkgs"
        else if flakeNixpkgsPath != null then
          flakeNixpkgsPath
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
      args = directTestArgs;
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
  if testPath != null && builtins.hasAttr testPath testsMeta then
    builtins.getAttr testPath testsMeta
  else if directSingleTestAvailable then
    directTestLib.testMeta directTest
  else
    builtins.getAttr testPath testsMeta
else if mode == "testJson" then
  if directSingleTestAvailable then directTest.test.json else builtins.getAttr testPath tests
else
  builtins.throw "Unsupported mode '${mode}'"
