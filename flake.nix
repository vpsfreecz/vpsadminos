{
  description = "vpsAdminOS flake";

  outputs =
    { self }:
    {
      nixosConfigurations = {
        container = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerStable = import ./os/lib/nixos-container/stable/vpsadminos.nix;

        containerUnstable = import ./os/lib/nixos-container/unstable/vpsadminos.nix;
      };
    };
}
