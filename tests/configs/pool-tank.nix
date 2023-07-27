{ config, pkgs, lib, ... }:
{
  boot.zfs.pools.tank = {
    layout = [
      { devices = [ "sda" ]; }
    ];
    importAttempts = lib.mkDefault 3;
    doCreate = true;
    install = true;
  };
}
