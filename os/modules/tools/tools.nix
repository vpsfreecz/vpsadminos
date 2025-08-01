# This module generates os-install, os-rebuild,
# os-generate-config, etc. (inspired by nixos-* tools)

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

  os-install = makeProg {
    name = "os-install";
    src = ./os-install.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      path = makeBinPath [ os-enter ];
    };
  };

  os-rebuild =
    let
      fallback = import ./nix-fallback-paths.nix;
    in
    makeProg {
      name = "os-rebuild";
      src = ./os-rebuild.sh;
      replacements = {
        shell = "${pkgs.bash}/bin/bash";
        nix = pkgs.nix;
        nix_x86_64_linux = fallback.x86_64-linux;
        nix_i686_linux = fallback.i686-linux;
      };
    };

  os-generate-config = makeProg {
    name = "os-generate-config";
    src = ./os-generate-config.pl;
    replacements = {
      perl = "${pkgs.perl}/bin/perl -I${pkgs.perlPackages.FileSlurp}/lib/perl5/site_perl";
      inherit (config.system.vpsadminos) release;
    };
  };

  os-version = makeProg {
    name = "os-version";
    src = ./os-version.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      inherit (config.system.vpsadminos) version revision;
      inherit (config.system) codeName;
    };
  };

  os-enter = makeProg {
    name = "os-enter";
    src = ./os-enter.sh;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
    };
  };

in

{

  config = {

    environment.systemPackages = [
      os-install
      os-rebuild
      os-generate-config
      os-version
      os-enter
    ];

    system.build = {
      inherit
        os-install
        os-generate-config
        os-rebuild
        os-enter
        ;
    };

  };

}
