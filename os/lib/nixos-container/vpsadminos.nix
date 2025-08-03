# This file provides compatibility for NixOS to run in a container on vpsAdminOS
# hosts.
#
# If you're experiencing issues, try updating this file to the latest version
# from vpsAdminOS repository.
#
# For NixOS stable:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/stable/vpsadminos.nix
#
# For NixOS unstable:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/unstable/vpsadminos.nix
#
{
  config,
  ...
}:
{
  assertions = [
    {
      assertion = false;
      message = ''
        Please choose vpsadminos.nix for your NixOS version:

        NixOS stable: https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/stable/vpsadminos.nix

        NixOS unstable: https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/unstable/vpsadminos.nix
      '';
    }
  ];
}
