{ config, pkgs, lib, ... }:
{
  # example of a webserver using declarative containers

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

    demoRoot = pkgs.runCommand "makeDemo" {} ''
      mkdir $out
      echo 'Hello from NixOS running on vpsAdminOS!' > $out/index.html
    '';
  in
  {
    webserver =
      { config =
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
        pool = "tank";
        user = sampleUser;
        interfaces = [ ifbr ];
        autostart.enable = true;
      };
  };
}
