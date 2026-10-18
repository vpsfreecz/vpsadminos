{ pkgs, makeSystem }:
let
  inherit (pkgs) lib;
  availableKernels = import ../os/packages/linux/available-kernels.nix { inherit lib; };

  metadata = package: {
    source = builtins.unsafeDiscardStringContext package.src.drvPath;
    patches = map (patch: builtins.unsafeDiscardStringContext (toString patch)) package.patches;
  };

  checkSelection =
    {
      name,
      kernelVersion ? null,
    }:
    let
      makeConfig =
        builtin:
        (makeSystem {
          modules = [
            {
              system.stateVersion = "26.05";
              boot = {
                zfsBuiltin = builtin;
              }
              # The default case must exercise normal kernel selection.
              // lib.optionalAttrs (kernelVersion != null) { inherit kernelVersion; };
            }
          ];
        }).config;

      builtin = makeConfig true;
      external = makeConfig false;
      selectedVersion = builtin.boot.kernelVersion;
      expectedVersion =
        if kernelVersion == null then availableKernels.stableKernelVersion else kernelVersion;
      tuple = availableKernels.kernels.${selectedVersion}.zfs;
      expected = metadata {
        src = pkgs.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "zfs";
          inherit (tuple) rev sha256;
        };
        patches = tuple.patches or [ ];
      };
      builtinPackage = metadata builtin.boot.zfsBuiltinPkg;
      externalPackage = metadata external.boot.kernelPackages.zfs;
    in
    {
      inherit
        name
        selectedVersion
        expected
        builtinPackage
        externalPackage
        ;
      assertions = [
        (lib.assertMsg (
          builtin.boot.zfsBuiltin && !external.boot.zfsBuiltin
        ) "${name}: fixture did not select both ZFS modes")
        (lib.assertMsg (selectedVersion == expectedVersion) "${name}: unexpected builtin kernel selection")
        (lib.assertMsg (
          external.boot.kernelVersion == selectedVersion
        ) "${name}: ZFS mode changes kernel selection")
        (lib.assertMsg (
          builtinPackage == expected
        ) "${name}: builtin ZFS differs from the declared source or ordered patches")
        (lib.assertMsg (
          externalPackage == expected
        ) "${name}: external ZFS differs from the declared source or ordered patches")
        (lib.assertMsg (
          builtinPackage == externalPackage
        ) "${name}: builtin and external ZFS source or ordered patches differ")
      ];
    };

  selections = [
    (checkSelection { name = "default"; })
  ]
  ++ map (
    kernelVersion:
    checkSelection {
      name = kernelVersion;
      inherit kernelVersion;
    }
  ) (builtins.attrNames availableKernels.kernels);
  assertions = lib.concatMap (selection: selection.assertions) selections;
in
# Only force package metadata. Kernel/module outputs must not become inputs to
# this check or be realized while evaluating it (run with IFD disabled).
builtins.deepSeq assertions (
  pkgs.runCommand "zfs-package-parity"
    {
      passthru.evaluation = map (selection: removeAttrs selection [ "assertions" ]) selections;
    }
    ''
      touch "$out"
    ''
)
