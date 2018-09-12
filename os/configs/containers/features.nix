{ config, pkgs, lib, ... }:
{
  # example of declarative containers
  # covering most features of osctl

  osctl.pools.tank = {
    users.sampleuser = let mapping = [ "0:666000:65536" ]; in {
      ugid = 5000;
      uidMap = mapping;
      gidMap = mapping;
    };

    users.largeuser = let mapping = [ "0:900000:1048576" ]; in {
      ugid = 5001;
      uidMap = mapping;
      gidMap = mapping;
    };

    groups."/" = {
      devices = (import <vpsadminos/os/modules/osctl/standard-devices.nix>) ++ [
        {
          name = "/dev/fuse";
          type = "char";
          major = "10";
          minor = "229";
          mode = "rwm";
        }
      ];
    };

    groups."/limited" = {
      cgparams = [
        { name = "memory.limit_in_bytes"; value = "10G"; }
        { name = "cpu.shares"; value = "768"; }
      ];
    };

    containers =
      let
        ifbr = {
          name = "eth0";
          type = "bridge";
          link = "lxcbr0";
          ipv4.addresses = [ { address = "192.168.1.2"; prefixLength = 24; } ];
        };

        ifrt = {
          name = "eth1";
          type = "routed";
          ipv4 =  {
            via = { address = "172.17.77.76"; prefixLength=30; };
            addresses = [ { address = "172.17.66.66"; prefixLength = 32; } ];
          };
          ipv6 = {
            via = { address = "2a03:3b40:7:666::"; prefixLength=64; };
            addresses = [ { address = "2a03:3b40:7:667::1"; prefixLength=64; } ];
          };
        };

        filelim = { name = "nofile"; soft = 1024; hard = 4096; };

        resolv = "1.1.1.1";

        mount = { fs = "/var/share"; mountpoint = "/mnt"; };
      in {
        defaults =
          { config =
              { config, pkgs, ... }:
              {
                # not much here
              };
            user = "sampleuser";
            autostart.enable = true;
          };

        webserver =
          { config =
              { config, pkgs, ... }:
              {
                services.nginx.enable = true;
                services.openssh.enable = true;
                networking.firewall.allowedTCPPorts = [ 80 ];
              };
            user = "sampleuser";
            group = "/default";
            interfaces = [ ifbr ];
            resolvers = [ resolv ];
            autostart.enable = true;
          };

        proxy =
          { config =
              { config, pkgs, ... }:
              {
                services.nginx.enable = true;
              };
            user = "largeuser";
            group = "/limited";
            nesting = true;
            interfaces = [ ifrt ];
            prlimits = [ filelim ];
          };

        hasmounts =
          { config =
              { config, pkgs, ... }:
              {
                # not much
              };
            user = "largeuser";
            mounts = [ mount ];
          };
      };
  };
}
