{ nixpkgsPath }: (import ./nixos-modules.nix { inherit nixpkgsPath; }) ++ (import ./os-modules.nix)
