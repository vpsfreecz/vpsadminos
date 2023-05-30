let
  nixpkgs = import <nixpkgs> {};

  allTests = import ./all-tests.nix {};

  testMeta = t:
    if t.type == "single" then
      { inherit (t) type; inherit (t.test.config) name description expectFailure; }
    else if t.type == "template" then
      { inherit (t) type template args; inherit (t.test.config) name description expectFailure; }
    else
      abort "unsupported test type";

  meta = nixpkgs.lib.mapAttrs (k: v: testMeta v) allTests;
in meta
