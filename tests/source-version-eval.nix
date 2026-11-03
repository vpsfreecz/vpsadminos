# Run with nix eval --impure --raw --file tests/source-version-eval.nix.
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  provider = {
    outPath = "/provider-os";
    rev = "0123456789abcdef0123456789abcdef01234567";
    shortRev = "0123456";
  };
  captured = {
    sourcePath = "/provider-os";
    revision = "abcdef0123456789abcdef0123456789abcdef01";
    shortRev = "abcdef0";
    dirty = true;
  };
  evaluate =
    source: sourceInfo: overrides:
    (lib.evalModules {
      modules = [
        {
          options.system.vpsadminos = {
            revision = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            revisionDirty = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            versionSuffix = lib.mkOption {
              type = lib.types.str;
              default = "pre-git";
            };
          };
        }
        (import ../os/lib/source-version.nix { inherit source sourceInfo; })
        { system.vpsadminos = overrides; }
      ];
    }).config.system.vpsadminos;
  clean = evaluate provider null { };
  dirty = evaluate {
    outPath = "/provider-os";
    dirtyRev = "${provider.rev}-dirty";
    dirtyShortRev = "0123456-dirty";
  } null { };
  snapshot = evaluate provider captured { };
  external = evaluate provider (captured // { sourcePath = "/external-caller"; }) { };
  unknown = evaluate { outPath = "/unknown"; } null { };
  packaged = evaluate provider (
    captured
    // {
      revision = null;
      shortRev = null;
      dirty = null;
    }
  ) { revision = "packaged-revision"; };
  # Select the real option declarations and automatic Git definitions. A fixed
  # ordinary-checkout boundary makes this independent of the check's own .git
  # file/directory form and exercises their actual override priorities.
  ordinaryGitMetadata =
    source: sourceInfo: overrides:
    let
      realVersion =
        config: options:
        import ../os/modules/misc/version.nix {
          inherit options;
          # Unrelated kernel/version fields needed by the real evidence JSON.
          config = config // {
            boot = {
              kernelVersion = "fixture";
              kernelPackages.kernel = {
                modDirVersion = "fixture";
                configfile = "/kernel.config";
              };
              kernel.sysctl = { };
            };
            system = config.system // {
              vpsadminos = {
                version = "fixture";
                nixpkgsVersion = "fixture";
                nixpkgsRevision = null;
              }
              // config.system.vpsadminos;
            };
          };
          pkgs = { };
          lib = lib // {
            pathIsDirectory = _: true;
            commitIdFromGitRepo = _: provider.rev;
          };
        };
      evaluated = lib.evalModules {
        modules = [
          (
            { config, options, ... }:
            let
              version = realVersion config options;
            in
            {
              options.system.vpsadminos = lib.getAttrs [
                "revision"
                "revisionDirty"
                "versionSuffix"
              ] version.options.system.vpsadminos;
              config.system.vpsadminos = lib.getAttrs [
                "revision"
                "versionSuffix"
              ] version.config.system.vpsadminos;
            }
          )
          (import ../os/lib/source-version.nix { inherit source sourceInfo; })
          { system.vpsadminos = overrides; }
        ];
      };
    in
    {
      metadata = evaluated.config.system.vpsadminos;
      evidence =
        builtins.fromJSON
          (realVersion evaluated.config evaluated.options)
          .config.environment.etc."vpsadminos/security-evidence.json".text;
    };
  ordinaryNative = ordinaryGitMetadata (
    provider
    // {
      rev = captured.revision;
      shortRev = captured.shortRev;
    }
  ) null { };
  ordinaryCaptured = ordinaryGitMetadata provider captured { };
  ordinaryOverride = ordinaryGitMetadata provider captured {
    revision = "explicit";
    revisionDirty = false;
    versionSuffix = ".explicit";
  };
  ordinaryShortOverride = ordinaryGitMetadata provider captured { revision = "0123456"; };
  ordinaryNullOverride = ordinaryGitMetadata provider captured { revision = null; };
  ordinaryAbsent = ordinaryGitMetadata { outPath = "/unknown"; } null { };
  ordinaryUnknown = ordinaryGitMetadata provider (
    captured
    // {
      revision = null;
      shortRev = null;
      dirty = null;
    }
  ) { };
  # Read metadata through the real OS test constructor without building it.
  machineMetadata =
    framework: overrides:
    let
      test =
        import ./make-test.nix
          ({ pkgs }: {
            name = "source-version";
            description = "source version module evaluation";
            machine.config =
              {
                config,
                ...
              }:
              {
                system.vpsadminos = overrides;
                system.systemBuilderArgs.passthru.sourceVersion = {
                  inherit (config.system.vpsadminos) revision revisionDirty versionSuffix;
                };
              };
            testScript = "";
          })
          {
            pkgs = flake.inputs.nixpkgs.outPath;
            testFramework = framework;
          };
    in
    test.config.machines.machine.toplevel.sourceVersion;
  framework = flake.lib.testFramework // {
    sourceVersionModule = import ../os/lib/source-version.nix {
      source = provider;
      sourceInfo = captured;
    };
  };
  constructed = machineMetadata framework { };
  legacy = machineMetadata (builtins.removeAttrs framework [ "sourceVersionModule" ]) {
    revision = "legacy-explicit";
  };
  explicit = machineMetadata framework {
    revision = "explicit";
    versionSuffix = ".explicit";
    revisionDirty = false;
  };
  override = evaluate provider captured {
    revision = "explicit";
    revisionDirty = false;
    versionSuffix = ".explicit";
  };
in
assert
  clean.revision == provider.rev && !clean.revisionDirty && clean.versionSuffix == ".git.0123456";
assert
  dirty.revision == provider.rev
  && dirty.revisionDirty
  && dirty.versionSuffix == ".git.0123456-dirty";
assert
  snapshot.revision == captured.revision
  && snapshot.revisionDirty
  && snapshot.versionSuffix == ".git.abcdef0";
assert external == clean;
assert unknown.revision == null && unknown.versionSuffix == "pre-git";
assert packaged.revision == "packaged-revision";
assert
  override == {
    revision = "explicit";
    revisionDirty = false;
    versionSuffix = ".explicit";
  };
assert constructed == snapshot;
assert legacy.revision == "legacy-explicit";
assert explicit == override;
assert ordinaryNative.metadata == (snapshot // { revisionDirty = false; });
assert
  ordinaryNative.evidence.revision == captured.revision && !ordinaryNative.evidence.revisionDirty;
assert ordinaryCaptured.metadata == snapshot;
assert
  ordinaryCaptured.evidence.revision == captured.revision && ordinaryCaptured.evidence.revisionDirty;
assert ordinaryOverride.metadata == override;
assert ordinaryOverride.evidence.revision == "explicit" && !ordinaryOverride.evidence.revisionDirty;
assert ordinaryShortOverride.evidence.revision == "0123456";
assert ordinaryNullOverride.evidence.revision == null;
assert
  ordinaryAbsent.metadata == {
    revision = "0123456";
    versionSuffix = ".git.0123456";
    revisionDirty = true;
  };
assert ordinaryAbsent.evidence.revision == provider.rev && ordinaryAbsent.evidence.revisionDirty;
assert ordinaryUnknown == ordinaryAbsent;
"source identity preserves provider, snapshot and explicit metadata\n"
