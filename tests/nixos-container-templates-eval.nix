# Capture the actual template modules' writeText outputs as evaluator files.
# This checks rendered flakes/configuration/locks without building tarballs.
let
  # Generated locks must name the checkout's actual Git revision, including
  # dirtyRev during development. A plain path flake has no revision metadata.
  vpsadminos = builtins.getFlake "git+file://${toString ../.}";
  stable = vpsadminos.inputs.nixpkgs;
  unstable = vpsadminos.inputs.nixpkgsUnstable;
  lib = stable.lib;
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  stableNixpkgsNode = lock.nodes.${lock.nodes.root.inputs.nixpkgs};
  unstableNixpkgsNode = lock.nodes.${lock.nodes.root.inputs.nixpkgsUnstable};
  impermanenceNode = lock.nodes.${lock.nodes.root.inputs.impermanence};
  impermanenceNixpkgsNode = lock.nodes.${impermanenceNode.inputs.nixpkgs};
  homeManagerNode = lock.nodes.${impermanenceNode.inputs."home-manager"};
  revision = vpsadminos.rev or (builtins.substring 0 40 vpsadminos.dirtyRev);
  check = name: condition: if condition then true else throw "NixOS template check failed: ${name}";
  evaluateTemplate =
    channel: includeImpermanence:
    let
      nixpkgs = if channel == "stable" then stable else unstable;
      nixpkgsNode = if channel == "stable" then stableNixpkgsNode else unstableNixpkgsNode;
      guestLib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      # The first-boot cp commands identify each file as actually emitted by the
      # template. No second implementation of the renderer is used here.
      rendered =
        import
          (
            ../os/lib/nixos-container
            + "/${channel}/${if includeImpermanence then "impermanence" else "minimal"}.nix"
          )
          {
            inherit
              impermanenceNode
              impermanenceNixpkgsNode
              homeManagerNode
              nixpkgsNode
              stableNixpkgsNode
              unstableNixpkgsNode
              ;
            impermanence = vpsadminos.inputs.impermanence;
            vpsadminosGithubRev = revision;
            lib = guestLib;
            pkgs = pkgs // {
              writeText = builtins.toFile;
            };
            modulesPath = "${nixpkgs}/nixos/modules";
            config.nix.package.out = "/nix-package";
          };
      copyLines = lib.filter (line: lib.hasPrefix "cp /nix/store/" line) (
        map lib.trim (lib.splitString "\n" rendered.boot.postBootCommands)
      );
      files = builtins.listToAttrs (
        map (
          line:
          let
            words = lib.splitString " " line;
          in
          {
            name = builtins.baseNameOf (builtins.elemAt words 2);
            value = builtins.elemAt words 1;
          }
        ) copyLines
      );
      guestLock = builtins.fromJSON (builtins.readFile files."flake.lock");
      guestFlake = import files."flake.nix";
      # Resolve ./configuration.nix next to the real generated flake text.
      # builtins.toFile cannot create a directory; rewrite only this file path.
      resolvedFlake = builtins.toFile "resolved-template-flake.nix" (
        lib.replaceStrings [ "./configuration.nix" ] [ files."configuration.nix" ] (
          builtins.readFile files."flake.nix"
        )
      );
      guestInputs = {
        inherit nixpkgs vpsadminos;
      }
      // lib.optionalAttrs includeImpermanence {
        impermanence = vpsadminos.inputs.impermanence;
      };
      evaluated = (import resolvedFlake).outputs guestInputs;
      config = evaluated.nixosConfigurations.vps.config;
      moduleName = if channel == "stable" then "containerStable" else "containerUnstable";
      expectedModule = vpsadminos.nixosModules.${moduleName};
      explicit = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          expectedModule
          files."configuration.nix"
        ]
        ++ lib.optional includeImpermanence vpsadminos.inputs.impermanence.nixosModules.impermanence;
        specialArgs.inputs = guestInputs;
      };
      follows =
        if includeImpermanence then
          [
            "impermanence"
            "nixpkgs"
          ]
        else
          [
            "vpsadminos"
            "impermanence"
            "nixpkgs"
          ];
    in
    check "${channel}/${if includeImpermanence then "impermanence" else "minimal"}" (
      guestFlake.inputs.nixpkgs.url
      == "github:${nixpkgsNode.original.owner}/${nixpkgsNode.original.repo}/${nixpkgsNode.original.ref}"
      && guestLock.version == 7
      && guestLock.nodes.root.inputs.nixpkgs == "nixpkgs"
      && guestLock.nodes.root.inputs.vpsadminos == "vpsadminos"
      && (guestLock.nodes.root.inputs ? impermanence) == includeImpermanence
      && guestLock.nodes.nixpkgs.locked == nixpkgsNode.locked
      && guestLock.nodes.vpsadminos-nixpkgs.locked == stableNixpkgsNode.locked
      && guestLock.nodes.vpsadminos-nixpkgs-unstable.locked == unstableNixpkgsNode.locked
      && guestLock.nodes.vpsadminos.locked.rev == revision
      && guestLock.nodes."home-manager".inputs.nixpkgs == follows
      && config.system.stateVersion == guestLib.trivial.release
      && config.boot.isContainer
      && config.system.build.toplevel.drvPath == explicit.config.system.build.toplevel.drvPath
      && lib.hasInfix "vpsadminos.nixosModules.${moduleName}" (builtins.readFile files."flake.nix")
      && (
        !includeImpermanence
        || (
          lib.any (
            directory: directory.directory == "/var/lib/nixos"
          ) config.environment.persistence."/persistent".directories
          && lib.any (file: file.file == "/etc/machine-id") config.environment.persistence."/persistent".files
        )
      )
    );
in
{
  stable = evaluateTemplate "stable" false;
  stableImpermanence = evaluateTemplate "stable" true;
  unstable = evaluateTemplate "unstable" false;
  unstableImpermanence = evaluateTemplate "unstable" true;
}
