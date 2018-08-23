{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  system = config.nixpkgs.system;

  # Get a submodule without any embedded metadata:
  _filter = x: filterAttrs (k: v: k != "_module") x;

  addrToStr = a: "${a.address}/${toString a.prefixLength}";
  boolToStr = x: if x then "true" else "false";

  osctlTarball = name: cfg:
    assert hasPrefix "/" cfg.group.name;
    import ../lib/make-osctl-tarball.nix {
      inherit (pkgs) stdenv writeText;
      rootFs = cfg.path;
      metadata = {
        type = "full";
        format = "tar";
        user = cfg.user.name;
        group = cfg.group.name;
        container = name;
        datasets = [];
        exported_at = 1;
      };
      ctconf = {
        user = cfg.user.name;
        group = cfg.group.name;
        dataset = "tank/ct/${name}";
        distribution = "nixos";
        version = "18.09";
        arch = "${toString (head (splitString "-" system))}";
        net_interfaces = cfg.interfaces;
        cgparams = cfg.cgparams;
        devices = cfg.devices;
        prlimits = cfg.prlimits;
        mounts = cfg.mounts;
        autostart = cfg.autostart;
        hostname = name;
        dns_resolvers = cfg.resolvers;
        nesting = boolToStr cfg.nesting;
      };
      userconf = {
        ugid = cfg.user.ugid;
        offset = cfg.user.offset;
        size = cfg.user.size;
      };
      groupconf = {
        cgparams = cfg.group.cgparams;
        devices = cfg.group.devices;
      };
    };

  osctl = "${pkgs.osctl}/bin/osctl";

  mkService = name: cfg: {
    run = ''
      sv check osctld >/dev/null || exit 1
      ${osctl} pool show -o name ${cfg.pool} 2>&1 >/dev/null || exit 1

      ${osctl} ct show ${name} &> /dev/null
      hasCT=$?
      if [ "$hasCT" != "0" ]; then
        echo "Importing container '${name}'"
        ${osctl} --pool ${cfg.pool} ct import ${osctlTarball name cfg}/*.tar
        ${optionalString (cfg.autostart != null) ''
          echo "Starting container '${name}'"
          ${osctl} ct start ${name}
        ''}
      fi

      sv once ct-${name}
    '';
  };

  mkServices = mapAttrs' (name: cfg:
    nameValuePair "ct-${name}" (mkService name cfg)
  ) config.containers;

  addrOpts = v:
    assert v == 4 || v == 6;
    { options = {
        address = mkOption {
          type = types.str;
          description = ''
            IPv${toString v} address of the interface. Leave empty to configure the
            interface using DHCP.
          '';
        };

        prefixLength = mkOption {
          type = types.addCheck types.int (n: n >= 0 && n <= (if v == 4 then 32 else 128));
          description = ''
            Subnet mask of the interface, specified as the number of
            bits in the prefix (<literal>${if v == 4 then "24" else "64"}</literal>).
          '';
        };
      };
    };

  netInterface = { lib, pkgs, ...}: {
    options = {
      type = mkOption {
        type = types.enum [ "bridge" "routed" ];
        description = "Network interface type";
      };
      name = mkOption {
        type = types.str;
        example = "eth0";
        description = "Network interface name";
      };
      hwaddr = mkOption {
        type = types.str;
        example = "52:54:00:2d:09:26";
        default = "";
        description = "Network interface hardware address";
      };
      link = mkOption {
        type = types.str;
        example = "lxcbr0";
        default = "";
        description = ''
          Link this network interface to bridge

          (type = "bridge" only)
        '';
      };
      ipv4.addresses = mkOption {
        type =  types.listOf (types.submodule (addrOpts 4));
        default = [];
        example = [
          { address = "10.0.0.1"; prefixLength = 16; }
          { address = "192.168.1.1"; prefixLength = 24; }
        ];
        description = ''
          List of IPv4 addresses that will be statically assigned to the interface.
        '';
        apply = x: map addrToStr x;
      };

      ipv4.via = mkOption {
        type =  types.nullOr (types.submodule (addrOpts 4));
        default = null;
        apply = x: if x != null then addrToStr x else x;
        description = ''
          IPv4 address of the interconnecting network (/30)

          (type = "routed" only)
        '';
      };
      ipv6.addresses = mkOption {
        type =  types.listOf (types.submodule (addrOpts 6));
        default = [];
        example = [
          { address = "2a03:3b40:7:666::"; prefixLength = 64; }
        ];
        description = ''
          List of IPv6 addresses that will be statically assigned to the interface.
        '';
        apply = x: map addrToStr x;
      };
      ipv6.via = mkOption {
        type =  types.nullOr (types.submodule (addrOpts 6));
        default = null;
        apply = x: if x != null then addrToStr x else x;
        description = ''
          IPv6 address of the interconnecting network (/30)

          (type = "routed" only)
        '';
      };
    };
  };

  mkNetInterfacesOption = mkOption {
    type = types.listOf (types.submodule netInterface);
    default = [];
    example = [
      { name = "eth0";
        type = "bridge";
        link = "lxcbr0";
        ipv4.addresses = [ { address = "10.0.0.1"; prefixLength = 16; } ];
      }
      { name = "eth1";
        type = "routed";
        ipv4 =  {
          via = { address = "172.17.77.76"; prefixLength=30; };
          addresses = [ { address = "172.17.66.66"; prefixLength = 32; } ];
        };
        ipv6 = {
          via = { address = "2a03:3b40:7:666::"; prefixLength=64; };
          addresses = [ { address = "2a03:3b40:7:667::1"; prefixLength=64; } ];
        };
      }
    ];

    description = ''
      Network interface configuration

      See also https://vpsadminos.org/user-guide/networking/
    '';

    apply = x: map (iface: filterAttrs (n: v: !(n == "ipv4" || n == "ipv6")) (iface //
          { ip_addresses.v4 = iface.ipv4.addresses;
            ip_addresses.v6 = iface.ipv6.addresses;
          } //
            (if iface.type == "routed" then
            { via.v4 = iface.ipv4.via;
              via.v6 = iface.ipv6.via;
            }
            else {})
          ))
          (map _filter x);
  };

  device = { lib, pkgs, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        example = "/dev/fuse";
        description = "Device name";
      };

      type = mkOption {
        type = types.str;
        example = "char";
        description = "Device type";
      };

      major = mkOption {
        type = types.ints.positive;
        example = 229;
        description = "Device major ID";
      };

      minor = mkOption {
        type = types.ints.positive;
        example = 10;
        description = "Device minor ID";
      };

      mode = mkOption {
        type = types.enum ["r" "rw" "w"];
        example = "rw";
      };
    };
  };

  mkDevicesOption = mkOption {
    type = types.listOf (types.submodule device);
    default = [];
    example = [
      { name = "/dev/fuse";
        major = 10;
        minor = 229;
        mode = "rw";
      }
    ];
    apply = x: map _filter x;
    description = ''
      Devices allowed in this group

      See also https://vpsadminos.org/containers/devices/
    '';
  };

  cgparam = { lib, pkgs, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        example = "memory.limit_in_bytes";
        description = "CGroup parameter name";
      };
      value = mkOption {
        type = types.str;
        example = "10G";
        apply = x: [ x ];
        description = "CGroup parameter value";
      };
      subsystem =  mkOption {
        type = types.str;
        example = "memory";
        description = "CGroup subsystem name";
      };
    };
  };

  mkCGParamsOption = mkOption {
    type = types.listOf (types.submodule cgparam);
    default = [];
    example = [
      { name = "memory.limit_in_bytes";
        value = "10G";
        subsystem = "memory";
      }
    ];

    apply = x: map _filter x;
    description = ''
      CGroup parameters

      See also https://vpsadminos.org/containers/resources/
    '';
  };

  prlimit = { lib, pkgs, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        example = "nproc";
        description = "Process resource limit name";
      };

      soft = mkOption {
        type = with types; either ints.positive (enum [ "unlimited" ]);
        example = 2048;
        description = "Soft limit";
        apply = toString;
      };

      hard = mkOption {
        type = with types; either ints.positive (enum [ "unlimited" ]);
        example = 4096;
        description = "Hard limit";
        apply = toString;
      };
    };
  };

  mkPrlimitsOption = mkOption {
    type = types.listOf (types.submodule prlimit);
    default = [];
    example = [
      { name = "nofile";
        soft = 1024;
        hard = 4096;
      }
    ];

    apply = x: map _filter x;
    description = ''
      Process resource limits

      See also https://vpsadminos.org/containers/resources/#process-resource-limits
    '';
  };

  mount = { lib, pkgs, ...}: {
    options = {
      fs = mkOption {
        type = types.str;
        example = "/var/shared";
        default = "";
        description = "Filesystem mountpoint (host side)";
      };

      dataset = mkOption {
        type = types.nullOr types.str;
        example = "subdataset";
        default = null;
        description = "Relative path to containers dataset";
      };

      mountpoint = mkOption {
        type = types.str;
        example = "/mnt";
        description = "Filesystem mountpoint (container side)";
      };

      type = mkOption {
        type = types.enum [ "bind" ];
        default = "bind";
        description = "Mount type";
      };

      opts = mkOption {
        type = types.str;
        default = "bind,create=dir,rw";
        example = "bind,create=dir,rw";
        description = "Mount options";
      };

      automount = mkOption {
        type = types.bool;
        default = true;
        description = "Mount automatically";
        apply = boolToStr;
      };
    };
  };

  mkMountsOption = mkOption {
    type = types.listOf (types.submodule mount);
    default = [];
    example = [
      { fs = "/var/shared";
        mountpoint = "/mnt";
      }
    ];

    apply = x: map _filter x;
    description = ''
      Container mounts

      See also https://vpsadminos.org/user-guide/mounts/
    '';
  };

  autostart = { lib, pkgs, ...}: {
    options = {
      enable = mkEnableOption "Enable container autostart";
      priority = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Autostart priority";
      };
      delay = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Autostart delay";
      };
    };
  };

  mkAutostartOption = mkOption {
    type = types.nullOr (types.submodule autostart);
    default = null;
    example = {
      enable = true;
      priority = 10;
      delay = 5;
    };

    apply = x: if x != null && x.enable then filterAttrs (k: v: k != "enable") (_filter x) else null;
    description = ''
      Autostart options

      See also https://vpsadminos.org/containers/auto-starting/
    '';
  };

  container = { config, options, name, ... }: {
    options = {
      config = mkOption {
        description = ''
          A specification of the desired configuration of this
          container, as a NixOS module.
        '';
        type = lib.mkOptionType {
          name = "Toplevel NixOS config";
          merge = loc: defs: (import <nixpkgs/nixos/lib/eval-config.nix> {
            inherit system;
            modules =
              let
                hasBridge = any (i: i.type == "bridge") config.interfaces;
                extraConfig =
                  { boot.isContainer = true;

                    networking.hostName = mkDefault name;
                    networking.useDHCP = hasBridge;

                    imports = [ ../lib/nixos-container/configuration.nix ];

                  };
              in [ extraConfig ] ++ (map (x: x.value) defs);
            prefix = [ "containers" name ];
          }).config;
        };
      };

      path = mkOption {
        type = types.path;
        example = "/nix/var/nix/profiles/containers/webserver";
        description = ''
          As an alternative to specifying
          <option>config</option>, you can specify the path to
          the evaluated NixOS system configuration, typically a
          symlink to a system profile.
        '';
      };

      pool = mkOption {
        type = types.str;
        example = "tank";
        description = ''
          Name of a zpool installed into osctl that the container should be
          stored on.
        '';
      };

      user = {
        name = mkOption {
          type = types.str;
          example = "myuser01";
          description = "User this container should belong to";
        };
        ugid = mkOption {
          type = types.ints.positive;
          example = 5000;
          description = "UID/GID of the system user that is used to run containers";
        };
        offset = mkOption {
          type = types.ints.positive;
          example = 666000;
          description = "Mapping for user and group IDs (maps container UID 0 to this offset";
        };
        size = mkOption {
          type = types.ints.positive;
          example = 65536;
          description = "number of mapped user and group IDs";
        };
      };

      group = {
        name = mkOption {
          type = types.strMatching "^/.*";
          default = "/default";
          example = "/custom";
          description = ''
            Name of the osctl group.

            Each group represents a cgroup in all subsystems.
            There are always two groups present: the root group and the default group.

            See also https://vpsadminos.org/containers/resources/
          '';
        };

        # per group
        cgparams = mkCGParamsOption;
        devices = mkDevicesOption;
      };

      # per container
      cgparams = mkCGParamsOption;
      devices = mkDevicesOption;
      prlimits = mkPrlimitsOption;
      mounts = mkMountsOption;

      interfaces = mkNetInterfacesOption;
      resolvers = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "1.1.1.1"
          "10.0.0.1"
        ];
        description = "List of nameservers";
      };

      autostart = mkAutostartOption;
      nesting = mkEnableOption "Enable container nesting";
    };
    config = mkMerge [
      (mkIf options.config.isDefined {
        path = config.config.system.build.tarball;
      })
    ];
  };
in
{
  ###### interface

  options = {
    containers = mkOption {
      type = types.attrsOf (types.submodule container);
      default = {};
      example = literalExample "";
      description = "CTs to include";
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.containers != {}) {
      runit.services = mkServices;
    })
  ];
}
