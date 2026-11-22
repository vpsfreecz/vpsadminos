# Capture the actual template modules' writeText outputs as evaluator files.
# This checks rendered flakes/configuration/locks without building tarballs.
let
  # Generated locks must name the checkout's actual Git revision, including
  # dirtyRev during development. A plain path flake has no revision metadata.
  vpsadminos = builtins.getFlake "git+file://${toString ../.}";
  stable = vpsadminos.inputs.nixpkgs;
  unstable = vpsadminos.inputs.nixpkgsUnstable;
  historical = import ../os/lib/nixos-container/stable/historical-nixpkgs.nix;
  system = "x86_64-linux";
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
    route: includeImpermanence:
    let
      isUnstable = route == "unstable";
      expectedRelease =
        if route == "stable" then
          "26.11"
        else if isUnstable then
          unstable.lib.trivial.release
        else
          route;
      nixpkgs =
        if route == "stable" then
          stable
        else if isUnstable then
          unstable
        else
          historical.${route}.input;
      nixpkgsNode =
        if route == "stable" then
          stableNixpkgsNode
        else if isUnstable then
          unstableNixpkgsNode
        else
          historical.${route}.node;
      guestLib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      variant = if includeImpermanence then "impermanence" else "minimal";
      channel = if isUnstable then "unstable" else "stable";
      moduleDir = vpsadminos.outPath + "/os/lib/nixos-container/${channel}";
      template = moduleDir + "/${variant}.nix";
      modulesPath = "${nixpkgs}/nixos/modules";
      specialArgs = {
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
      };
      # The first-boot cp commands identify each file as actually emitted by the
      # template. No second implementation of the renderer is used here.
      rendered = import template (
        specialArgs
        // {
          inherit modulesPath;
          lib = guestLib;
          pkgs = pkgs // {
            writeText = builtins.toFile;
          };
          config.nix.package.out = "/nix-package";
        }
      );
      imageConfig =
        (nixpkgs.lib.nixosSystem {
          inherit system pkgs specialArgs;
          modules = [ template ];
        }).config;
      suffix = lib.replaceStrings [ "." ] [ "_" ] route;
      package = "template-${lib.optionalString includeImpermanence "impermanence-"}${suffix}";
      build = if includeImpermanence then "impermanenceTarball" else "tarball";
      rawFile = if isUnstable then "vpsadminos.nix" else "vpsadminos-${expectedRelease}.nix";
      baseImports =
        (import (moduleDir + "/base.nix") {
          inherit modulesPath pkgs;
          lib = guestLib;
        }).imports;
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
      expectedRev =
        {
          "25.11" = "b6018f87da91d19d0ab4cf979885689b469cdd41";
          "26.05" = "94c3211b0ee8ba969a3f12eb4aff8ba0f72971dd";
          stable = "fe08e4f8a90a7db0eeaa0916247187cf09ea4c71";
          unstable = unstable.rev;
        }
        .${route};
      expectedUrl =
        "github:NixOS/nixpkgs/" + (if route == "stable" then expectedRev else "nixos-${route}");
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
      moduleName = if isUnstable then "containerUnstable" else "containerStable";
      expectedModule =
        if isUnstable then
          vpsadminos.nixosModules.containerUnstable
        else
          vpsadminos.nixosModules.containers.${expectedRelease};
      explicit = nixpkgs.lib.nixosSystem {
        inherit system;
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
      name = "${route}/${variant}";
    in
    rec {
      inputLock = check "${name} input lock" (
        guestFlake.inputs.nixpkgs.url == expectedUrl
        && guestLock.nodes.nixpkgs.original == builtins.parseFlakeRef expectedUrl
        && guestLock.nodes.nixpkgs.locked.rev == expectedRev
        && builtins.parseFlakeRef guestFlake.inputs.nixpkgs.url == nixpkgsNode.original
        && builtins.parseFlakeRef guestFlake.inputs.vpsadminos.url == guestLock.nodes.vpsadminos.original
        && (
          !includeImpermanence
          || builtins.parseFlakeRef guestFlake.inputs.impermanence.url == impermanenceNode.original
        )
        && guestLock.version == 7
        && guestLock.nodes.root.inputs.nixpkgs == "nixpkgs"
        && nixpkgs.rev == nixpkgsNode.locked.rev
        && nixpkgs.narHash == nixpkgsNode.locked.narHash
        && guestLock.nodes.root.inputs.vpsadminos == "vpsadminos"
        && (guestLock.nodes.root.inputs ? impermanence) == includeImpermanence
        &&
          guestLock.nodes.nixpkgs == {
            inherit (nixpkgsNode) locked original;
          }
        &&
          guestLock.nodes.vpsadminos-nixpkgs == {
            inherit (stableNixpkgsNode) locked original;
          }
        &&
          guestLock.nodes.vpsadminos-nixpkgs-unstable == {
            inherit (unstableNixpkgsNode) locked original;
          }
        && guestLock.nodes.impermanence.original == impermanenceNode.original
        && guestLock.nodes.vpsadminos.locked.rev == revision
        && guestLock.nodes."home-manager".inputs.nixpkgs == follows
      );
      guest =
        inputLock
        && check name (
          config.system.nixos.release == expectedRelease
          && config.system.stateVersion == expectedRelease
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
      image =
        assert check "${name} tarball release, module, and package" (
          imageConfig.system.nixos.release == expectedRelease
          && imageConfig.system.stateVersion == expectedRelease
          && builtins.elem (toString (moduleDir + "/${rawFile}")) (map toString baseImports)
          && imageConfig.system.build.${build}.drvPath == vpsadminos.packages.${system}.${package}.drvPath
        );
        {
          inherit package variant;
          release = imageConfig.system.nixos.release;
          rev = nixpkgsNode.locked.rev;
          module = "${channel}/${rawFile}";
          drvPath = vpsadminos.packages.${system}.${package}.drvPath;
        };
    };
  templates = {
    "25.11" = evaluateTemplate "25.11" false;
    "25.11-impermanence" = evaluateTemplate "25.11" true;
    "26.05" = evaluateTemplate "26.05" false;
    "26.05-impermanence" = evaluateTemplate "26.05" true;
    stable = evaluateTemplate "stable" false;
    stableImpermanence = evaluateTemplate "stable" true;
    unstable = evaluateTemplate "unstable" false;
    unstableImpermanence = evaluateTemplate "unstable" true;
  };
in
builtins.mapAttrs (_: template: template.guest) templates
// {
  inputLocks = builtins.mapAttrs (_: template: template.inputLock) templates;
  images = builtins.mapAttrs (_: template: template.image) templates;
}
