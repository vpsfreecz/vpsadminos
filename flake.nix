{
  description = "vpsAdminOS flake";

  outputs = { self }: {
    nixosConfigurations.container = import ./os/lib/nixos-container/vpsadminos.nix;
  };
}
