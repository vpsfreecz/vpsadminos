{ repoRoot }:
(builtins.getFlake (builtins.toString repoRoot)).outPath
