{
  forAllSystems,
  impermanence,
  nixpkgs,
  nixpkgsUnstable,
  root,
  testFramework,
  vpsadminosSystem,
}:
{
  checks = forAllSystems (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
      sys = vpsadminosSystem {
        inherit system;
        modules = [
          (
            { ... }:
            {
              system.stateVersion = "26.05";
            }
          )
        ];
      };
    in
    {
      qemu-disk-lifecycle = import (root + "/tests/qemu-disk-lifecycle-check.nix") {
        inherit pkgs;
        makeSystem = args: vpsadminosSystem (args // { inherit system; });
      };
      nixos-disk-image-reuse = import (root + "/tests/nixos-disk-image-reuse-check.nix") {
        inherit nixpkgs system testFramework;
      };
      nixos-container-persistence = import (root + "/tests/nixos-container-persistence-check.nix") {
        pkgs = import nixpkgs { inherit system; };
        source = root;
        inherit
          system
          nixpkgs
          nixpkgsUnstable
          impermanence
          ;
      };
      os-eval = sys.config.system.build.toplevel;
      vpsadminos-disk-image-reuse = import (root + "/tests/vpsadminos-disk-image-reuse-check.nix") {
        inherit nixpkgs system testFramework;
      };
      zfs-package-parity = import (root + "/tests/zfs-package-parity-check.nix") {
        pkgs = import nixpkgs { inherit system; };
        makeSystem = args: vpsadminosSystem (args // { inherit system; });
      };
    }
  );
}
