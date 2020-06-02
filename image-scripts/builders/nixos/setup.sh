cat <<EOF > /etc/nixos/configuration.nix
{ config, pkgs, ... }:
{
  imports = [
    <nixpkgs/nixos/modules/virtualisation/container-config.nix>
    <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
    ./build.nix
    ./networking.nix
  ];

  environment.systemPackages = with pkgs; [
    git
    gnumake
  ];

  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = "18.09";
}
EOF

# Set NIX_PATH and other stuff
. /etc/profile

# Configure the system
nixos-rebuild switch
