{ configuration ? let cfg = builtins.getEnv "VPSADMINOS_CONFIG"; in if cfg == "" then null else import cfg
, pkgs ? <nixpkgs>
  # extra modules to include
, modules ? []
  # extra arguments to be passed to modules
, extraArgs ? {}
  # target system
, system ? builtins.currentSystem
, platform ? null
, vpsadmin ? null }:

let
  pkgs_ = import pkgs { inherit system; platform = platform; config = {}; };
  pkgsModule = rec {
    _file = ./default.nix;
    key = _file;
    config = {
      nixpkgs.system = pkgs_.lib.mkDefault system;
      nixpkgs.overlays = import ./overlays { lib = pkgs_.lib; inherit vpsadmin; };
    };
  };
  baseModules = import ./modules/module-list.nix;
  evalConfig = modulesArgs: pkgs_.lib.evalModules {
    prefix = [];
    check = true;
    modules = baseModules ++ [ pkgsModule ] ++ modules ++ modulesArgs;
    args = extraArgs;
  };
in
rec {
  test1 = evalConfig (if configuration != null then [configuration] else []);
  runner = test1.config.system.build.runvm;
  config = test1.config;
}
