{
  configuration ?
    let
      cfg = builtins.getEnv "VPSADMINOS_CONFIG";
    in
    if cfg == "" then null else import cfg,
  pkgs ? null,
  importedPkgs ? null,
  nixpkgsPath ? null,
  # extra modules to include
  modules ? [ ],
  # extra arguments to be passed to modules
  extraArgs ? { },
  # target system
  system ? builtins.currentSystem,
  platform ? null,
}:

let
  pkgsPath =
    if nixpkgsPath != null then
      nixpkgsPath
    else if importedPkgs != null then
      importedPkgs.path
    else
      pkgs;

  pkgs_ =
    if isNull importedPkgs then
      import pkgsPath {
        inherit system;
        platform = platform;
        config = { };
      }
    else
      importedPkgs;

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
  baseModules = import ./modules/module-list.nix { nixpkgsPath = pkgsPath; };
  evalConfig =
    modulesArgs:
    pkgs_.lib.evalModules {
      prefix = [ ];
      modules = baseModules ++ [ pkgsModule ] ++ modules ++ modulesArgs;

      # Make these available externally, before `config` is evaluated,
      # so module imports can safely use them without recursion.
      specialArgs = extraArgs // {
        modulesPath = pkgsPath + "/nixos/modules";
        nixpkgsPath = pkgsPath;
      };
    };
in
rec {
  # Raw evalModules result (better name than `test1`)
  eval = evalConfig (if configuration != null then [ configuration ] else [ ]);

  # Backward compatibility: keep old name
  test1 = eval;

  # Conventional exports for external consumers (confctl, tooling, etc.)
  config = eval.config;
  options = eval.options;

  # Export the module-system pkgs (includes nixpkgs.config + overlays)
  pkgs = eval._module.args.pkgs;

  # Convenience
  runner = eval.config.system.build.runvm;
  toplevel = eval.config.system.build.toplevel;
}
