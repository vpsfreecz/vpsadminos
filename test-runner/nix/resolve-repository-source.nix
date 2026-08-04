{
  repoRoot,
  nixpkgsPath,
  nixSystem,
}:
let
  pkgs = import nixpkgsPath { system = nixSystem; };
  source = (builtins.getFlake (builtins.toString repoRoot)).outPath;
in
pkgs.runCommandLocal "test-runner-repository-source" { } ''
  mkdir "$out"
  ln -s ${source} "$out/source"
''
