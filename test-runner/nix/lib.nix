{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  lib ? null,
  suitePath ? ./suite,
  suiteArgs ? { },
  configuration ? null,
  testConfig ? { },
}:
let
  nixpkgs = import pkgs { inherit system; };
  l = if lib == null then nixpkgs.lib else lib;

  makeSingleTest =
    {
      test,
      args ? { },
    }:
    let
      testModule = import (suitePath + "/${test}.nix") (
        {
          inherit
            pkgs
            system
            configuration
            testConfig
            ;
        }
        // suiteArgs
        // {
          testArgs = args;
        }
      );
    in
    {
      name = test;
      value = {
        type = "single";
        test = testModule;
        testArgs = args;
      };
    };

  makeTemplateTest =
    { template, instances }:
    map (
      args:
      let
        t = import (suitePath + "/${template}.nix") (
          {
            inherit
              pkgs
              system
              configuration
              testConfig
              ;
          }
          // suiteArgs
          // {
            templateArgs = args;
          }
        );
      in
      {
        name = "${template}@${t.instance}";
        value = {
          type = "template";
          template = template;
          templateArgs = args;
          test = t;
        };
      }
    ) instances;

  makeTest =
    v:
    if builtins.isAttrs v then
      if builtins.hasAttr "template" v then
        makeTemplateTest v
      else
        makeSingleTest {
          test = v.test;
          args = if builtins.hasAttr "args" v then v.args else { };
        }
    else
      makeSingleTest { test = v; };

  makeTests = list: builtins.listToAttrs (l.flatten (map makeTest list));

  testScriptsMeta =
    testCfg:
    l.mapAttrs (name: ts: {
      description = ts.description or null;
      expectFailure = ts.expectFailure or null;
      attempts = ts.attempts or null;
      tags = ts.tags or [ ];
      labels = ts.labels or { };
    }) testCfg.testScripts;

  testMeta =
    t:
    if t.type == "single" then
      {
        inherit (t) type testArgs;
        inherit (t.test.config)
          name
          description
          attempts
          expectFailure
          tags
          labels
          ;
        testScriptJobs = t.test.config.testScriptJobs or 1;
        testScripts = testScriptsMeta t.test.config;
      }
    else if t.type == "template" then
      {
        inherit (t) type template templateArgs;
        inherit (t.test.config)
          name
          description
          attempts
          expectFailure
          tags
          labels
          ;
        testScriptJobs = t.test.config.testScriptJobs or 1;
        testScripts = testScriptsMeta t.test.config;
      }
    else
      builtins.throw "unsupported test type '${t.type}'";

  metaFromAllTests = allTests: l.mapAttrs (_: v: testMeta v) allTests;
in
{
  inherit
    makeSingleTest
    makeTemplateTest
    makeTest
    makeTests
    testMeta
    metaFromAllTests
    ;
}
