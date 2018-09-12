{ config, pkgs, lib, ... }:
{
  # example of simple container

  osctl.pools.tank = {
    users.sampleuser = let mapping = [ "0:666000:65536" ]; in {
      ugid = 5000;
      uidMap = mapping;
      gidMap = mapping;
    };

    containers.simple = {
      config =
        { config, pkgs, ... }:
        {
          # not much here
        };

      user = "sampleuser";

      interfaces = [
        {
          name = "eth0";
          type = "bridge";
          link = "lxcbr0";
        }
      ];

      autostart.enable = true;
    };
  };
}
