{
  description = "VPS Admin OS flake";

  outputs = { self }: {
    nixosConfigurations.default = import ./os/lib/nixos-container/vpsadminos.nix;
  };

}
