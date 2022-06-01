{ configuration ? let cfg = builtins.getEnv "VPSADMINOS_CONFIG"; in if cfg == "" then null else import cfg
, pkgs ? <nixpkgs>
, importedPkgs ? null
  # extra modules to include
, modules ? []
  # extra arguments to be passed to modules
, extraArgs ? {}
  # target system
, system ? builtins.currentSystem
, platform ? null }:

let
  pkgs_ =
    if isNull importedPkgs then
      import pkgs { inherit system; platform = platform; config = {}; }
    else importedPkgs;

  pkgsModule = rec {
    _file = ./default.nix;
    key = _file;
    config = {
      _module = {
        args = extraArgs;
        check = true;
      };
      nixpkgs.system = pkgs_.lib.mkDefault system;
      nixpkgs.overlays = import ./overlays;
    };
  };
  baseModules = import ./modules/module-list.nix;
  evalConfig = modulesArgs: pkgs_.lib.evalModules {
    prefix = [];
    modules = baseModules ++ [ pkgsModule ] ++ modules ++ modulesArgs;
  };
in
rec {
  test1 = evalConfig (if configuration != null then [configuration] else []);
  runner = test1.config.system.build.runvm;
  config = test1.config;
}
