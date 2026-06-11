templateFn:
{
  templateArgs ? null,
  templateArgsInJson ? null,
  configuration ?
    let
      cfg = builtins.getEnv "VPSADMINOS_CONFIG";
    in
    if cfg == "" then null else import cfg,
  pkgs ? <nixpkgs>,
  # extra modules to include
  modules ? [ ],
  # extra arguments to be passed to modules
  extraArgs ? { },
  testConfig ? { },
  testFramework ? null,
  # target system
  system ? builtins.currentSystem,
}:
let
  nixArgs =
    if !(isNull templateArgs) then
      templateArgs
    else if !(isNull templateArgsInJson) then
      builtins.fromJSON templateArgsInJson
    else
      abort "provide templateArgs or templateArgsInJson";

  templateAttrs = templateFn nixArgs;

  testFn = import ./make-test.nix (templateAttrs.test);

  testAttrs = testFn (
    {
      inherit
        configuration
        pkgs
        modules
        extraArgs
        system
        testConfig
        ;
    }
    // (
      if testFramework != null then
        {
          inherit testFramework;
        }
      else
        { }
    )
  );
in
{
  instance = templateAttrs.instance;
  inherit (testAttrs) config json;
}
