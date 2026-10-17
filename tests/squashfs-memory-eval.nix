# Evaluate cache flags and option wiring without building an image.
let
  pkgsPath =
    let
      env = builtins.getEnv "TEST_RUNNER_NIXPKGS_PATH";
    in
    if env != "" then
      builtins.toPath env
    else
      (builtins.getFlake (toString ../.)).inputs.nixpkgs.outPath;
  lib = (import pkgsPath { }).lib;
  builder =
    memoryMiB: noStrip:
    import ../os/lib/make-squashfs.nix {
      inherit lib memoryMiB noStrip;
      stdenv.mkDerivation = attrs: attrs;
      gnutar = null;
      squashfsTools = null;
      closureInfo = _: "/closure";
    };
  moduleArgs = {
    inherit lib;
    nixpkgsPath = pkgsPath;
    pkgs.callPackage = _: args: args;
    config = {
      system = {
        squashfsMemoryMiB = 1234;
        squashfsCompression = [
          "zstd"
          "-Xcompression-level"
          "10"
        ];
        secretsDir = null;
        build.toplevel = "/system";
      };
      isoImage.storeContents = [ "/system" ];
    };
  };
  rootModule = import ../os/modules/system/activation/top-level.nix moduleArgs;
  isoModule = import ../os/modules/installer/cd-dvd/iso-image.nix moduleArgs;
  testModule = import ./configs/vpsadminos/base.nix moduleArgs;
  option = rootModule.options.system.squashfsMemoryMiB;
  testValue =
    overrides:
    (lib.evalModules {
      modules = [
        {
          options.system.squashfsMemoryMiB = option;
          config.system.squashfsMemoryMiB = testModule.system.squashfsMemoryMiB;
        }
        overrides
      ];
    }).config.system.squashfsMemoryMiB;
  checkBranch =
    noStrip:
    let
      bounded = (builder 2048 noStrip).buildCommand;
      unbounded = (builder null noStrip).buildCommand;
    in
    assert lib.hasInfix "-mem 2048M" bounded;
    assert !(lib.hasInfix "-mem " unbounded);
    assert lib.hasInfix (lib.escapeShellArgs [
      "-comp"
      "zstd"
      "-Xcompression-level"
      "10"
    ]) bounded;
    assert !(lib.hasInfix "-processors" bounded);
    assert lib.hasInfix (if noStrip then "| sqfstar" else "mksquashfs nix-path-registration") bounded;
    true;
in
assert checkBranch true;
assert checkBranch false;
assert option.default == null;
assert !(option.type.check 0);
assert option.type.check 2048;
assert testValue { } == 2048;
assert testValue { system.squashfsMemoryMiB = 4096; } == 4096;
assert testValue { system.squashfsMemoryMiB = null; } == null;
assert rootModule.config.system.build.squashfs.memoryMiB == 1234;
assert isoModule.config.system.build.squashfsStore.memoryMiB == 1234;
"squashfs cache flags and module wiring passed\n"
