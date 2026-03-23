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
  builtins.getAttr testPath testsMeta
else if mode == "testJson" then
  builtins.getAttr testPath tests
else
  builtins.throw "Unsupported mode '${mode}'"
