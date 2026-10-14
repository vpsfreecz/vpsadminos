{
  pkgs,
  source,
  system,
  nixpkgs,
  nixpkgsUnstable,
  impermanence,
}:
let
  fixtures = import ./fixtures/nixos-container-persistence.nix {
    inherit
      system
      nixpkgs
      nixpkgsUnstable
      impermanence
      ;
  };
  evaluation = import ./nixos-container-persistence-eval.nix {
    inherit source system;
    inherit (pkgs) lib;
    inherit (fixtures) oldSource impermanenceModule;
    fixtures = fixtures.releases;
  };
  shellFixtures = pkgs.lib.mapAttrs (name: fixture: {
    snippet = pkgs.writeText "persistent-specialfs-${name}.sh" fixture.snippet;
    inherit (fixture) earlyMountScript mode selectedOptions;
  }) evaluation.shellFixtures;
in
builtins.deepSeq evaluation.assertions (
  pkgs.runCommand "nixos-container-persistence"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.util-linux
        pkgs.gnused
        pkgs.gawk
      ];
      passthru = { inherit evaluation shellFixtures; };
    }
    ''
      ${pkgs.lib.concatMapStringsSep "\n" (name: ''
        bash ${./nixos-container-persistence-shell.sh} ${shellFixtures.${name}.snippet} ${
          shellFixtures.${name}.earlyMountScript
        } ${shellFixtures.${name}.mode} ${pkgs.lib.escapeShellArg shellFixtures.${name}.selectedOptions}
      '') (builtins.attrNames shellFixtures)}
      mkdir "$out"
      cp ${pkgs.writeText "persistence-evaluation.json" (builtins.toJSON evaluation.assertions)} "$out/evaluation.json"
    ''
)
