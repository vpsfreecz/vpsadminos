{ config, pkgs, lib, ... }:
{
  _module.args = {
    oslib = {
      systemd = import ../../lib/systemd.nix { inherit lib; };
    };
  };
}
