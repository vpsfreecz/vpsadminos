# Used for test runs
let
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
in
pkgs.mkShell {
  packages = with pkgs; [
    netcat
    sshpass
  ];

  # This shell can be entered from inside osctl-image's own shell.
  shellHook = "";
}
