{
  pkgs ? null,
  nixpkgsPath ? null,
}:
let
  nixpkgsPathEnv = builtins.getEnv "NIXPKGS_PATH";
  resolvedNixpkgsPath =
    if nixpkgsPath != null then
      nixpkgsPath
    else if nixpkgsPathEnv != "" then
      nixpkgsPathEnv
    else
      null;

  pkgs_ =
    if pkgs != null then
      pkgs.extend (import ../../overlays/ruby.nix)
    else if resolvedNixpkgsPath != null then
      import resolvedNixpkgsPath {
        overlays = [ (import ../../overlays/ruby.nix) ];
      }
    else
      throw "os/packages/test-runner/entry.nix: provide pkgs or nixpkgsPath (or set NIXPKGS_PATH)";
in
pkgs_.callPackage ./default.nix { }
