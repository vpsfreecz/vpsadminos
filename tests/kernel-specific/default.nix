{ lib }:
let
  inherit (import ../../os/packages/linux/available-kernels.nix { inherit lib; }) kernels;
  entries = builtins.removeAttrs (builtins.readDir ./.) [ "default.nix" ];
in
builtins.listToAttrs (
  lib.mapAttrsToList (
    kernelVersion: type:
    let
      path = ./. + "/${kernelVersion}";
      marker = path + "/default.nix";
      registration = import marker { inherit kernelVersion; };
      runnerTests = registration.runnerTests or [ ];
      validRunnerTest =
        test:
        let
          name = if builtins.isAttrs test then test.template or test.test or null else test;
        in
        builtins.isString name
        && builtins.match "[a-zA-Z0-9_-][a-zA-Z0-9_.-]*(/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*)*" name != null
        && builtins.pathExists (path + "/suite/${name}.nix");
    in
    if type != "directory" || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" kernelVersion == null then
      throw "Invalid kernel-specific test directory: ${kernelVersion}"
    else if !builtins.hasAttr kernelVersion kernels then
      throw "Kernel-specific test directory has no catalog owner: ${kernelVersion}"
    else if (builtins.readDir path)."default.nix" or null != "regular" then
      throw "Missing regular kernel-specific test registration: ${kernelVersion}/default.nix"
    else if
      !builtins.isAttrs registration
      ||
        (builtins.removeAttrs registration [
          "runnerTests"
          "checks"
        ]) != { }
      || !builtins.isList runnerTests
      || !builtins.all validRunnerTest runnerTests
      || (registration ? checks && !builtins.isFunction registration.checks)
    then
      throw "Invalid kernel-specific test registration: ${kernelVersion}/default.nix"
    else
      lib.nameValuePair kernelVersion registration
  ) entries
)
