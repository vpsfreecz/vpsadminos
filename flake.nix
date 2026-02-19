{
  description = "vpsAdminOS flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      vpsadminosSystem =
        {
          system,
          pkgs ? nixpkgs.legacyPackages.${system},
          modules ? [ ],
          specialArgs ? { },
          configuration ? null,
          platform ? null,
        }:
        import ./os/default.nix {
          inherit
            system
            modules
            configuration
            platform
            ;
          importedPkgs = pkgs;
          nixpkgsPath = pkgs.path;
          extraArgs = specialArgs;
        };
    in
    {
      lib.vpsadminosSystem = vpsadminosSystem;

      nixosModules.vpsadminos =
        { pkgs, ... }:
        {
          imports = import ./os/modules/module-list.nix { nixpkgsPath = pkgs.path; };
        };

      nixosConfigurations = {
        container = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerStable = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerUnstable = import ./os/lib/nixos-container/unstable/vpsadminos.nix;
      };

      checks.x86_64-linux.os-eval =
        let
          sys = vpsadminosSystem {
            system = "x86_64-linux";
            modules = [
              (
                { ... }:
                {
                  system.stateVersion = "25.11";
                }
              )
            ];
          };
        in
        sys.config.system.build.toplevel;
    };
}
