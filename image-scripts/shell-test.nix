# Used for test runs
let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "vpsadminos-templates";

  buildInputs = [
    pkgs.sshpass
  ];

  # shellHook needs to be unset in case osctl-template is run from its own
  # nix-shell. osctl-template sets up ruby and bundler in its shellHook, it is
  # inherited by nested nix-shells and breaks them.
  shellHook = "";
}
