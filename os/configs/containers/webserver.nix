{ config, pkgs, lib, ... }:
let
  demoRoot = pkgs.runCommand "demoRoot" {} ''
    mkdir $out
    echo "Hello from NixOS running on vpsAdminOS" > $out/index.html
  '';
in
{
  # example of a webserver using declarative containers

  osctl.pools.tank = {
    users.webuser = let mapping = [ "0:999000:65536" ]; in {
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

      user = "webuser";

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
