{
  repoRoot,
  system ? "x86_64-linux",
  testConfigPath ? null,
  mode ? "testsMetaAll",
  testPath ? null,
  testArgsJson ? null,
  selectedTestsJson ? "[]",
  configuration ?
    let
      cfg = builtins.getEnv "VPSADMINOS_CONFIG";
    in
    if cfg == "" then null else import cfg,
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
    path:
    path != null
    && builtins.pathExists (repoRoot + "/test-runner/nix/lib.nix")
    && builtins.pathExists (testsRoot + "/suite/${path}.nix");
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
      inherit configuration;
      testConfig = effectiveTestConfig;
    };

  directTest =
    path: args:
    (directTestLib.makeSingleTest {
      test = path;
      inherit args;
    }).value;

  useConfiguredFramework = testConfigPath != null || (configuration != null && haveTestFramework);
  configuredFramework = if testConfigPath != null then testFramework else flake.lib.testFramework;

  tests =
    if !useConfiguredFramework then
      flake.tests.${system}
    else
      configuredFramework.mkTests {
        inherit system;
        testConfig = effectiveTestConfig;
        testsRoot = repoRoot + "/tests";
        inherit configuration;
      };

  testsMeta =
    if !useConfiguredFramework then
      flake.testsMeta.${system}
    else
      configuredFramework.mkTestsMeta {
        inherit system;
        testConfig = effectiveTestConfig;
        testsRoot = repoRoot + "/tests";
        inherit configuration;
      };
  resolveTestJson =
    path: args:
    if directSingleTestAvailable path then
      (directTest path args).test.json
    else
      builtins.getAttr path tests;

  selected = builtins.fromJSON selectedTestsJson;
  manifest = map (request: {
    inherit (request) id;
    json = resolveTestJson request.path (request.testArgs or { });
  }) selected;
  # Preserve the JSON string contexts: this output roots all selected JSONs and
  # their referenced closures, rather than only a list of discarded path text.
  batchPkgs = import (builtins.toPath (builtins.getEnv "TEST_RUNNER_NIXPKGS_PATH")) {
    inherit system;
  };
  batch = batchPkgs.writeText "os-test-prebuild.json" (builtins.toJSON manifest);
in
if mode == "testsMetaAll" then
  testsMeta
else if mode == "testsMetaOne" then
  if testPath != null && builtins.hasAttr testPath testsMeta then
    builtins.getAttr testPath testsMeta
  else if directSingleTestAvailable testPath then
    directTestLib.testMeta (directTest testPath directTestArgs)
  else
    builtins.getAttr testPath testsMeta
else if mode == "testJson" then
  resolveTestJson testPath directTestArgs
else if mode == "testBatch" then
  batch
else
  builtins.throw "Unsupported mode '${mode}'"
