# This module generates vpsadminos-install, vpsadminos-rebuild,
# vpsadminos-generate-config, etc. (inspired by nixos-* tools)

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

with lib;

let
  cfg = config.installer;

  makeProg =
    {
      name,
      src,
      replacements ? { },
    }:
    pkgs.replaceVarsWith {
      dir = "bin";
      isExecutable = true;
      inherit name src replacements;
    };

  makeAlias =
    {
      name,
      target,
      targetName,
    }:
    pkgs.runCommand name { } ''
      mkdir -p $out/bin
      ln -s ${target}/bin/${targetName} $out/bin/${name}
    '';

  vpsadminos-install = makeProg {
    name = "vpsadminos-install";
    src = ./vpsadminos-install.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      nix = pkgs.nix;
      path = makeBinPath [ vpsadminos-enter ];
    };
  };

  vpsadminos-rebuild = makeProg {
    name = "vpsadminos-rebuild";
    src = ./vpsadminos-rebuild.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      nix = pkgs.nix;
    };
  };

  vpsadminos-generate-config = makeProg {
    name = "vpsadminos-generate-config";
    src = ./vpsadminos-generate-config.pl;
    replacements = {
      perl = "${pkgs.perl}/bin/perl -I${pkgs.perlPackages.FileSlurp}/lib/perl5/site_perl";
      hostPlatformSystem = pkgs.stdenv.hostPlatform.system;
      inherit (config.system.vpsadminos) release;
    };
  };

  vpsadminos-version = makeProg {
    name = "vpsadminos-version";
    src = ./vpsadminos-version.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      inherit (config.system.vpsadminos) version revision;
      inherit (config.system) codeName;
      json = builtins.toJSON {
        vpsadminosVersion = config.system.vpsadminos.version;
        vpsadminosRevision = config.system.vpsadminos.revision;
      };
    };
  };

  vpsadminos-enter = makeProg {
    name = "vpsadminos-enter";
    src = ./vpsadminos-enter.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      path = makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
      ];
    };
  };

  os-install = makeAlias {
    name = "os-install";
    target = vpsadminos-install;
    targetName = "vpsadminos-install";
  };

  os-rebuild = makeAlias {
    name = "os-rebuild";
    target = vpsadminos-rebuild;
    targetName = "vpsadminos-rebuild";
  };

  os-generate-config = makeAlias {
    name = "os-generate-config";
    target = vpsadminos-generate-config;
    targetName = "vpsadminos-generate-config";
  };

  os-version = makeAlias {
    name = "os-version";
    target = vpsadminos-version;
    targetName = "vpsadminos-version";
  };

  os-enter = makeAlias {
    name = "os-enter";
    target = vpsadminos-enter;
    targetName = "vpsadminos-enter";
  };

in

{

  config = {

    environment.systemPackages = [
      vpsadminos-install
      vpsadminos-rebuild
      vpsadminos-generate-config
      vpsadminos-version
      vpsadminos-enter
      os-install
      os-rebuild
      os-generate-config
      os-version
      os-enter
    ];

    system.build = {
      inherit
        vpsadminos-install
        vpsadminos-generate-config
        vpsadminos-rebuild
        vpsadminos-version
        vpsadminos-enter
        os-install
        os-generate-config
        os-rebuild
        os-version
        os-enter
        ;
    };

  };

}
