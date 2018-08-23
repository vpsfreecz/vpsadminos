{ config, pkgs, lib, ... }:
{
  # example of simple container

  containers = let
    sampleUser = {
      name = "sample";
      ugid = 5000;
      offset = 666000;
      size = 65536;
    };

    ifbr = {
      name = "eth0";
      type = "bridge";
      link = "lxcbr0";
    };
  in
  {
    simple =
      { config =
          { config, pkgs, ... }:
          {
            # not much here
          };
        pool = "tank";
        user = sampleUser;
        interfaces = [ ifbr ];
        autostart.enable = true;
      };
  };
}
