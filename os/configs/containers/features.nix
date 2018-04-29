{ config, pkgs, lib, ... }:
{
  # example of declarative containers
  # covering most features of osctl

  containers = let
    sampleUser = { name = "sample"; ugid = 5000; offset = 666000; size = 65536; };
    largeUser = { name = "large";  ugid = 5001; offset = 900000; size = 1048576; };

    memLimit = { name = "memory.limit_in_bytes"; value = "10G"; subsystem = "memory"; };
    cpuShares = { name = "cpu.shares"; value = "768"; subsystem = "cpu"; };
    limitedGroup = { name = "/limited"; cgparams = [ cpuShares memLimit ]; };

    fuse = { name = "/dev/fuse"; type = "char"; major = 10; minor = 229; mode = "rw"; };
    deviceGroup = { name = "/devices"; devices = [ fuse ]; };

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
  in
  {
    defaults =
      { config =
          { config, pkgs, ... }:
          {
            # not much here
          };
        user = sampleUser;
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
        user = sampleUser;
        group = deviceGroup;
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
        user = largeUser;
        group = limitedGroup;
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
        user = largeUser;
        mounts = [ mount ];
      };
  };
}
