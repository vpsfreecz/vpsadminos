{
  repoRoot,
  nixpkgsPath,
  nixSystem,
}:
let
  pkgs = import nixpkgsPath { system = nixSystem; };
  repoRootString = builtins.toString repoRoot;
  escapedRepoRoot = builtins.replaceStrings [ "%2F" ] [ "/" ] (
    pkgs.lib.strings.escapeURL repoRootString
  );
  flakeRef =
    if builtins.pathExists (repoRoot + "/.git") then
      "git+file://${escapedRepoRoot}"
    else
      "path:${escapedRepoRoot}";
  source = (builtins.getFlake flakeRef).outPath;
in
pkgs.runCommandLocal "test-runner-repository-source" { } ''
  mkdir "$out"
  ln -s ${source} "$out/source"
''
