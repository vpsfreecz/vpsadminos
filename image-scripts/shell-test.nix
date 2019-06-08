# Used for test runs
let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "vpsadminos-image-build-scripts";

  buildInputs = with pkgs; [
    netcat
    sshpass
  ];

  # shellHook needs to be unset in case osctl-image is run from its own
  # nix-shell. osctl-image sets up ruby and bundler in its shellHook, it is
  # inherited by nested nix-shells and breaks them.
  shellHook = "";
}
