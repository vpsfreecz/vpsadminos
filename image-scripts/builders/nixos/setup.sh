cat <<EOF > /etc/nixos/flake.nix
{
  inputs.vpsadminos.url = "github:vpsfreecz/vpsadminos";
  inputs.nixpkgs.follows = "vpsadminos/nixpkgsUnstable";

  outputs = { nixpkgs, vpsadminos, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vpsadminos.nixosModules.containerUnstable
      ];
    };
  };
}
EOF

cat <<EOF > /etc/nixos/configuration.nix
{ lib, pkgs, ... }:
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    gnumake
  ];

  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;
}
EOF

rm -f /etc/nixos/flake.lock

if [ -n "$NIX_CONFIG" ] ; then
  export NIX_CONFIG="$NIX_CONFIG
experimental-features = nix-command flakes"
else
  export NIX_CONFIG="experimental-features = nix-command flakes"
fi

# Set PATH and other login shell defaults
. /etc/profile

# Configure the system from the template flake
nixos-rebuild switch --flake /etc/nixos#vps
