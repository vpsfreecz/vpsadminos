{ config, pkgs, lib, ... }:
{
  boot.zfs.pools.tank = {
    layout = [
      { devices = [ "sda" ]; }
    ];
    doCreate = true;
    install = true;
  };
}
