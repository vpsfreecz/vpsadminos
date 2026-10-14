# Run with nix eval --impure --json --file tests/nixos-container-modules-eval.nix.
# Historical inputs use real option declarations, not a modern lib with a
# substituted release string. Fetch failures are distinct from assertion errors.
let
  vpsadminos = builtins.getFlake (toString ../.);
  lib = vpsadminos.inputs.nixpkgs.lib;
  fixtures = import ./fixtures/nixos-container-releases.nix { inherit vpsadminos; };
  modules = vpsadminos.nixosModules;
  releases = [
    "22.11"
    "23.05"
    "23.11"
    "24.05"
    "24.11"
    "25.05"
    "25.11"
    "26.05"
  ];
  alias = release: "container_${lib.replaceStrings [ "." ] [ "_" ] release}";
  nameservers = [
    "1.1.1.1"
    "2606:4700:4700::1111"
  ];
  check = name: condition: if condition then true else throw "NixOS container check failed: ${name}";

  # Exercise every selector leaf without pretending these are historical NixOS
  # evaluations. The real release evaluations below verify option compatibility.
  moduleArgs = {
    inherit lib;
    config = {
      fileSystems = { };
      systemd.mounts = [ ];
    };
    options.boot.specialFileSystems.type.getSubOptions = _: { };
    utils = {
      fsNeededForBoot = _: false;
      pathsNeededForBoot = [ ];
    };
    pkgs = {
      iproute2 = "/iproute2";
      bash = "/bash";
    };
  };
  moduleValue = module: builtins.toJSON (module moduleArgs);
  selectedValue =
    selector: release:
    moduleValue (
      builtins.head
        (selector {
          lib = lib // {
            trivial = lib.trivial // {
              inherit release;
              version = "${release}pre-git";
            };
          };
        }).imports
    );
  unknownReleases = [
    "21.11"
    "99.99"
    "26_05"
    "unstable"
    ""
  ];

  evaluate =
    nixpkgs: module:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        module
        { system.stateVersion = "22.11"; }
      ];
    };
  configuration =
    evaluated:
    let
      c = evaluated.config;
    in
    {
      release = c.system.nixos.release;
      stateVersion = c.system.stateVersion;
      isContainer = c.boot.isContainer;
      initScript = c.boot.loader.initScript.enable;
      nameservers = c.networking.nameservers;
      resolved =
        if lib.versionAtLeast c.system.nixos.release "26.05" then
          c.services.resolved.settings.Resolve.FallbackDNS
        else
          c.services.resolved.fallbackDns;
      networkingSetup = c.systemd.services.networking-setup.serviceConfig.ExecStart;
      oomd = c.systemd.services.systemd-oomd.enable;
      audit = c.systemd.sockets.systemd-journald-audit.enable;
      runKeys = c.boot.specialFileSystems."/run/keys".fsType;
      toplevel = c.system.build.toplevel.drvPath;
    };
  # This exact import is reused for each guest release, with stateVersion fixed.
  stableImport = modules.containerStable;
  realReleaseCheck =
    release: nixpkgs:
    let
      explicit = configuration (evaluate nixpkgs modules.containers.${release});
      automatic = configuration (evaluate nixpkgs stableImport);
      generic = configuration (evaluate nixpkgs modules.container);
      underscore = configuration (evaluate nixpkgs modules.${alias release});
    in
    check "real ${release} guest and unchanged stable import" (
      nixpkgs.lib.trivial.release == release
      && automatic == explicit
      && generic == explicit
      && underscore == explicit
      && automatic.release == release
      && automatic.stateVersion == "22.11"
      && automatic.isContainer
      && automatic.initScript
      && automatic.nameservers == nameservers
      && automatic.resolved == nameservers
      && !automatic.oomd
      && !automatic.audit
      && automatic.runKeys == "tmpfs"
    );
  stable = fixtures."26.05";
  unstable = fixtures.unstable;
  rawStable = import ../os/lib/nixos-container/stable/vpsadminos.nix;
  rawUnstable = import ../os/lib/nixos-container/unstable/vpsadminos.nix;
in
{
  exports = check "exact grouped keys, derived aliases, and no containerAuto" (
    builtins.attrNames modules.containers == releases
    && !(modules ? containerAuto)
    && lib.all (release: modules ? ${alias release}) releases
  );
  selectorMatrix = builtins.listToAttrs (
    map (
      release:
      let
        original = moduleValue (import (../os/lib/nixos-container/stable + "/vpsadminos-${release}.nix"));
      in
      {
        name = release;
        value = check "selector and aliases for ${release}" (
          moduleValue modules.containers.${release} == original
          && selectedValue modules.containerStable release == original
          && selectedValue modules.container release == original
          && moduleValue modules.${alias release} == original
        );
      }
    ) releases
  );
  unsupported = check "unknown releases fail during import selection" (
    lib.all (
      release:
      !(builtins.tryEval (
        builtins.deepSeq
          (modules.containerStable {
            lib = lib // {
              trivial = lib.trivial // {
                inherit release;
              };
            };
          }).imports
          true
      )).success
    ) unknownReleases
  );
  realReleases = lib.genAttrs [ "24.11" "25.11" "26.05" ] (
    release: realReleaseCheck release fixtures.${release}
  );
  guestLibrary = check "24.11 guest is distinct from captured 26.05 input" (
    lib.trivial.release == "26.05" && fixtures."24.11".lib.trivial.release == "24.11"
  );
  legacy = check "legacy latest stable and unstable exports retain raw behavior" (
    configuration (evaluate stable vpsadminos.nixosConfigurations.container)
    == configuration (evaluate stable rawStable)
    &&
      configuration (evaluate stable vpsadminos.nixosConfigurations.containerStable)
      == configuration (evaluate stable rawStable)
    &&
      configuration (evaluate unstable vpsadminos.nixosConfigurations.containerUnstable)
      == configuration (evaluate unstable rawUnstable)
    &&
      configuration (evaluate unstable modules.containerUnstable)
      == configuration (evaluate unstable rawUnstable)
  );
  # Literal quoted and guest-nixpkgs interpolated lookups must both import a leaf.
  groupedSyntax = check "quoted and interpolated release keys" (
    configuration (evaluate stable modules.containers."26.05")
    == configuration (evaluate stable modules.containers.${stable.lib.trivial.release})
  );
}
