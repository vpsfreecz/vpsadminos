let
  nixpkgs = import <nixpkgs> {};

  allTests = import ./all-tests.nix {};

  testMeta = t:
    if t.type == "single" then
      {
        inherit (t) type testArgs;
        inherit (t.test.config) name description expectFailure tags labels;
        testScripts = nixpkgs.lib.mapAttrs (name: ts: {
          description = ts.description or null;
          expectFailure = ts.expectFailure or null;
          tags = ts.tags or [];
          labels = ts.labels or {};
        }) t.test.config.testScripts;
      }
    else if t.type == "template" then
      {
        inherit (t) type template templateArgs;
        inherit (t.test.config) name description expectFailure tags labels;
        testScripts = nixpkgs.lib.mapAttrs (name: ts: {
          description = ts.description or null;
          expectFailure = ts.expectFailure or null;
          tags = ts.tags or [];
          labels = ts.labels or {};
        }) t.test.config.testScripts;
      }
    else
      abort "unsupported test type";

  meta = nixpkgs.lib.mapAttrs (k: v: testMeta v) allTests;
in meta
