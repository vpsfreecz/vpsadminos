{ config, pkgs, lib, ... }:
{
  # example of a webserver using declarative containers

  osctl.pools.tank = {
    users.sampleuser = let mapping = [ "0:666000:65536" ]; in {
      ugid = 5000;
      uidMap = mapping;
      gidMap = mapping;
    };

    containers.webserver = {
      config =
        { config, pkgs, ... }:
        {
          services.nginx = {
            enable = true;
            virtualHosts = {
              "demo.example.org" = {
                root = demoRoot;
                default = true;
              };
            };
          };

          services.openssh.enable = true;
          networking.firewall.allowedTCPPorts = [ 80 ];
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
