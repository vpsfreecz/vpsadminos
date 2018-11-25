{ pkgs ? import ./nixpkgs.nix }:
let
  overrides = {
    __nixPath = [ { prefix = "nixpkgs"; path = pkgs.path; } ] ++ builtins.nixPath;
    import = fn: scopedImport overrides fn;
    scopedImport = attrs: fn: scopedImport (overrides // attrs) fn;
    builtins = builtins // overrides;
  };
  vpsadminos = conf: builtins.scopedImport overrides ./os { nixpkgs = pkgs.path; configuration = conf; };

  vpsadminosDef = vpsadminos (import ./os/configs/default.nix);
in
rec {
  meta = {
    name = "vpsadminos";
    maintainer = "vpsFree";
  };

  toplevel = vpsadminosDef.config.system.build.toplevel;
}
