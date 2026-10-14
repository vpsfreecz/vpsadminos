# Immutable sources shared by the pure check and registered upgrade suite.
{
  system,
  nixpkgs ? null,
  nixpkgsUnstable ? null,
  impermanence ? null,
}:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  fetch = locked: builtins.fetchTree ({ type = "github"; } // locked);
  fromLock = name: fetch lock.nodes.${lock.nodes.root.inputs.${name}}.locked;
  release = source: {
    inherit source;
    lib = (import (source + "/lib")) // {
      nixosSystem = args: import (source + "/nixos/lib/eval-config.nix") (args // { inherit system; });
    };
  };
  oldMetadata = {
    owner = "vpsfreecz";
    repo = "vpsadminos";
    rev = "1150e37b1cc997b1728f2fda806a3433ef55b798";
    narHash = "sha256-PdZ1g1KtuxL/3T1E01jKhj3Npmkd4G8EJIzS0OSiaMA=";
  };
in
{
  releases = {
    "25.11" =
      release
        (fetch {
          owner = "NixOS";
          repo = "nixpkgs";
          rev = "b6018f87da91d19d0ab4cf979885689b469cdd41";
          narHash = "sha256-twXPFqFsrrY5r28Zh7Homgcp2gUMBgQ6WDS98Q/3xFI=";
        }).outPath;
    "26.05" = release (if nixpkgs == null then (fromLock "nixpkgs").outPath else nixpkgs.outPath);
    unstable = release (
      if nixpkgsUnstable == null then (fromLock "nixpkgsUnstable").outPath else nixpkgsUnstable.outPath
    );
  };
  impermanenceModule =
    (if impermanence == null then (fromLock "impermanence").outPath else impermanence.outPath)
    + "/nixos.nix";
  oldSource = (fetch oldMetadata).outPath;
  inherit oldMetadata;
}
