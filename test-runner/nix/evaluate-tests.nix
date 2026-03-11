{
  repoRoot,
  system ? "x86_64-linux",
  testConfigPath ? null,
  mode ? "testsMetaAll",
  testPath ? null,
}:
let
  flake = builtins.getFlake (builtins.toString repoRoot);

  testConfig = if testConfigPath == null then { } else import testConfigPath;

  tests = flake.lib.testFramework.mkTests {
    inherit system testConfig;
    testsRoot = repoRoot + "/tests";
    configuration = null;
  };

  testsMeta = flake.lib.testFramework.mkTestsMeta {
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
