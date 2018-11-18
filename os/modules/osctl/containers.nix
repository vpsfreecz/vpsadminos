{ config, lib, pkgs, utils, shared, ... }@args:
with utils;
with lib;

let
  system = config.nixpkgs.system;

  # Get a submodule without any embedded metadata:
  _filter = x: filterAttrs (k: v: k != "_module") x;

  addrToStr = a: "${a.address}/${toString a.prefixLength}";
  boolToStr = x: if x then "true" else "false";
  nullIfEmpty = s: if s == "" then null else s;

  buildDevices = devices: map (dev: {
    inherit (dev) type major minor mode;
    name = nullIfEmpty dev.name;
  }) devices;

  backends = {
    nixos = import ./containers/nixos.nix args;
    template = import ./containers/template.nix args;
  };

  backendFor = cfg:
    if cfg.distribution == null && cfg.template.type == "remote" then
      backends.nixos
    else
      backends.template;

  mkService = pool: name: cfg: (
    let
      osctl = "${pkgs.osctl}/bin/osctl";
      osctlPool = "${osctl} --pool ${pool}";

      osHooks = [ "pre-create" "on-create" "post-create" ];

      configuredHooks = filter ({hook, script}: script != null && !(elem hook osHooks))
                               (mapAttrsToList (hook: script:
                               { inherit hook script; }
                               ) cfg.hooks);

      hooks = concatStringsSep "\n" (map ({hook, script}:
        ''ln -sf ${script} "$hookDir/${hook}"''
      ) configuredHooks);

      hookCaller = hook: script: pkgs.writeScript "container-${name}-${hook}-caller" ''
        #!${pkgs.stdenv.shell}

        lines=( $(${osctlPool} ct show -Ho dataset,rootfs,lxc_path,lxc_dir,group_path,distribution,version,hostname ${name}) )
        ctExists=$?

        export OSCTL_HOOK_NAME="${hook}"
        export OSCTL_POOL_NAME="${pool}"
        export OSCTL_CT_ID="${name}"
        export OSCTL_CT_USER="${cfg.user}"
        export OSCTL_CT_GROUP="${cfg.group}"

        if [ "$ctExists" == "0" ] ; then
          export OSCTL_CT_DATASET="''${lines[0]}"
          export OSCTL_CT_ROOTFS="''${lines[1]}"
          export OSCTL_CT_LXC_PATH="''${lines[2]}"
          export OSCTL_CT_LXC_DIR="''${lines[3]}"
          export OSCTL_CT_CGROUP_PATH="''${lines[4]}"
          export OSCTL_CT_DISTRIBUTION="''${lines[5]}"
          export OSCTL_CT_VERSION="''${lines[6]}"
          export OSCTL_CT_HOSTNAME="''${lines[7]}"

          lines=( $(zfs get -Hp -o value mountpoint,org.vpsadminos.osctl:dataset ${pool}) )
          mountpoint="''${lines[0]}"
          osctlDataset="''${lines[1]}"

          [ "$osctlDataset" != "-" ] \
            && mountpoint="$(zfs get -Hp -o value mountpoint $osctlDataset)"

          export OSCTL_CT_LOG_FILE="$mountpoint/log/ct/${name}.log"
        fi

        ${script}
      '';

      conf = {
        user = cfg.user;
        group = cfg.group;
        dataset = "${pool}/ct/${name}";
        distribution = if cfg.distribution == null then "nixos" else cfg.distribution;
        version = if cfg.version == null then "18.09" else cfg.version;
        arch = if cfg.arch == null then (toString (head (splitString "-" system))) else cfg.arch;
        net_interfaces = cfg.interfaces;
        cgparams = shared.buildCGroupParams cfg.cgparams;
        devices = buildDevices cfg.devices;
        prlimits = cfg.prlimits;
        mounts = cfg.mounts;
        autostart = null; # autostart is handled by the runit service
        hostname = name;
        dns_resolvers = cfg.resolvers;
        nesting = boolToStr cfg.nesting;
        seccomp_profile = nullIfEmpty cfg.seccomp;
      };

      yml = pkgs.writeText "container-${name}.yml" (builtins.toJSON conf);

      backend = backendFor cfg;

      backendArgs = {
        inherit pool name cfg;
        inherit osctl osctlPool hooks hookCaller conf yml;
        inherit boolToStr;
      };

    in {
      run = backend.serviceRun backendArgs;

      log.enable = true;
      log.sendTo = "127.0.0.1";
    }
  );

  mkServices = pool: containers: mapAttrs' (name: cfg:
    nameValuePair "ct-${pool}-${name}" (mkService pool name cfg)
  ) containers;

  addrOpts = v:
    assert v == 4 || v == 6;
    { options = {
        address = mkOption {
          type = types.str;
          description = ''
            IPv${toString v} address.
          '';
        };

        prefixLength = mkOption {
          type = types.addCheck types.int (n: n >= 0 && n <= (if v == 4 then 32 else 128));
          description = ''
            Subnet mask of the address, specified as the number of
            bits in the prefix (<literal>${if v == 4 then "24" else "64"}</literal>).
          '';
        };
      };
    };

  netInterface = { config, lib, pkgs, ...}: {
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
      dhcp = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Determines whether the interface is configured using DHCP client
          within the container,

          (type = "bridge" only)
        '';
      };
      ipv4 = {
        routes = mkOption {
          type =  types.listOf (types.submodule (addrOpts 4));
          default = [];
          example = [
            { address = "10.0.0.0"; prefixLength = 16; }
            { address = "192.168.1.0"; prefixLength = 24; }
          ];
          description = ''
            List of IPv4 addresses that will be routed to the interface.
          '';
          apply = x: map addrToStr x;
        };
        addresses = mkOption {
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
        gateway = mkOption {
          type = types.str;
          default = "auto";
          description = ''
            IPv4 gateway for statically configured bridged interfaces.
            Set to <literal>auto</literal> to use the primary address from
            the linked interface, <literal>none</literal> to do not set any
            gateway or an IPv4 address.

            (type = "bridge" only)
          '';
        };
      };

      ipv6 = {
        routes = mkOption {
          type =  types.listOf (types.submodule (addrOpts 4));
          default = [];
          example = [
            { address = "2a03:3b40:7:666::"; prefixLength = 64; }
          ];
          description = ''
            List of IPv6 addresses that will be routed to the interface.
          '';
          apply = x: map addrToStr x;
        };
        addresses = mkOption {
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
        gateway = mkOption {
          type = types.str;
          default = "auto";
          description = ''
            IPv6 gateway for statically configured bridged interfaces.
            Set to <literal>auto</literal> to use the primary address from
            the linked interface, <literal>none</literal> to do not set any
            gateway or an IPv6 address.

            (type = "bridge" only)
          '';
        };
      };
    };

    config = mkMerge [
      (mkIf (config.type == "bridge") {
        dhcp = mkDefault true;
      })
    ];
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
          addresses = [ { address = "172.17.66.66"; prefixLength = 32; } ];
        };
        ipv6 = {
          addresses = [ { address = "2a03:3b40:7:667::1"; prefixLength=64; } ];
        };
      }
    ];

    description = ''
      Network interface configuration

      See also https://vpsadminos.org/user-guide/networking/
    '';

    apply = x: map (iface: filterAttrs (n: v: !(n == "ipv4" || n == "ipv6")) (iface //
          { routes.v4 = iface.ipv4.routes;
            routes.v6 = iface.ipv6.routes;
            ip_addresses.v4 = iface.ipv4.addresses;
            ip_addresses.v6 = iface.ipv6.addresses;
            gateways.v4 = iface.ipv4.gateway;
            gateways.v6 = iface.ipv6.gateway;
          }
          ))
          (map _filter x);
  };

  prlimit = { lib, pkgs, ...}: {
    options = {
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
    type = types.attrsOf (types.submodule prlimit);
    default = {
      nofile = {soft = 1024; hard = 1024*1024; };
    };
    apply = x: mapAttrs (k: v: _filter v) x;
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

                    imports = [ ../../lib/nixos-container/configuration.nix ];

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

      user = mkOption {
        type = types.str;
        example = "myuser01";
        description = ''
          Name of an osctl user declared by <option>osctl.users</option> that
          the container belongs to.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "/default";
        description = ''
          Name of an osctl group declared by <option>osctl.groups</option> that
          the container belongs to.
        '';
      };

      # per container
      distribution = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Name of the distribution to install.
        '';
      };

      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Version of the distribution to install.
        '';
      };

      arch = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Architecture of the distribution to install, must be compatible with
          the host's architecture.
        '';
      };

      vendor = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Template vendor for use with osctl remote repositories.
        '';
      };

      variant = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Template variant for use with osctl remote repositories.
        '';
      };

      template = {
        type = mkOption {
          type = types.enum [ "remote" "archive" "stream" ];
          default = "remote";
          description = ''
            Defines where to get the distribution template. Use
            <literal>remote</literal> to download templates from vpsAdminOS
            repositories, <literal>archive</literal> to use your own tar archive
            and <literal>stream</literal> to use your own gzipped ZFS stream.

            When set to <literal>archive</literal> or <literal>stream</literal>,
            option
            <option>osctl.pools.<pool>.containters.<container>.template.path</option>
            has to be set as well.
          '';
        };

        path = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path to tar archive or ZFS stream file containing the container's
            template if option
            <option>osctl.pools.<pool>.containters.<container>.template.type</option>
            is set to <literal>archive</literal> or <literal>stream</literal>.
          '';
        };

        repository = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Name of the remote repository the container's template is searched for
            if option
            <option>osctl.pools.<pool>.containters.<container>.template.type</option>
            is set to <literal>remote</literal>. When set to <literal>null</literal>,
            all pool's repositories are searched.
          '';
        };
      };

      cgparams = shared.mkCGParamsOption;
      devices = shared.mkDevicesOption;
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

      seccomp = mkOption {
        type = types.str;
        default = "";
        example = "/run/osctl/configs/lxc/common.seccomp";
        description = "Path to seccomp profile";
      };

      hooks = {
        pre-create = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>pre-create</literal> hook is run in the host's namespace
            before the container is created. If <literal>pre-create</literal>
            exits with status `1`, the creation attempt will be aborted
            and retried repeatedly, as the container's runit service restarts
            until the hook script exits with `0`. If
            <literal>pre-create</literal> exits with status `2`, the container
            will not be created and the runit service will not be automatically
            restarted.
          '';
        };

        on-create = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>on-create</literal> hook is run in the host's namespace
            after the container was created and configured, but before it is
            started. The script hook's exit status is not evaluated.
          '';
        };

        post-create = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>post-create</literal> hook is run in the host's namespace
            after the container was created, configured and started. The script
            hook's exit status is not evaluated.
          '';
        };

        pre-start = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>pre-start</literal> hook is run in the host's namespace
            before the container is mounted. The container's cgroups have
            already been configured and distribution-support code has been run.
            If <literal>pre-start</literal> exits with a non-zero status, the
            container's start is aborted.
          '';
        };

        veth-up = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>veth-up</literal> hook is run in the host's namespace when
            the veth pair is created. Names of created veth interfaces are
            available in environment variables <literal>OSCTL_HOST_VETH</literal>
            and <literal>OSCTL_CT_VETH</literal>. If <literal>veth-up</literal>
            exits with a non-zero status, the container's start is aborted.
          '';
        };

        pre-mount = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>pre-mount</literal> is run in the container's mount
            namespace, before its rootfs is mounted. The path to the container's
            runtime rootfs is in environment variable
            <literal>OSCTL_CT_ROOTFS_MOUNT</literal>. If
            <literal>pre-mount</literal> exits with a non-zero status, the
            container's start is aborted.
          '';
        };

        post-mount = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>post-mount</literal> is run in the container's mount
            namespace, after its rootfs and all LXC mount entries are mounted.
            The path to the container's runtime rootfs is in environment variable
            <literal>OSCTL_CT_ROOTFS_MOUNT</literal>. If
            <literal>post-mount</literal> exits with a non-zero status, the
            container's start is aborted.
          '';
        };

        on-start = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>on-start</literal> is run in the host's namespace, after
            the container has been mounted and right before its init process is
            executed. If <literal>on-start</literal> exits with a non-zero
            status, the container's start is aborted.
          '';
        };

        post-start = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>post-start</literal> is run in the host's namespace after
            the container entered state <literal>running</literal>. The
            container's init PID is passed in environment varible
            <literal>OSCTL_CT_INIT_PID</literal>. The script hook's exit status
            is not evaluated.
          '';
        };

        pre-stop = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>pre-stop</literal> hook is run in the host's namespace when
            the container is being stopped using <literal>ct stop</literal>. If
            <literal>pre-stop</literal> exits with a non-zero exit status,
            the container will not be stopped. This hook is not called when the
            container is shutdown from the inside.
          '';
        };

        on-stop = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>on-stop</literal> is run in the host's namespace when the
            container enters state <literal>stopping</literal>. The hook's exit
            status is not evaluated.
          '';
        };

        veth-down = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>veth-down</literal> hook is run in the host's namespace
            when the veth pair is removed. Names of the removed veth interfaces
            are available in environment variables
            <literal>OSCTL_HOST_VETH</literal> and
            <literal>OSCTL_CT_VETH</literal>. The hook's exit status is not
            evaluated.
          '';
        };

        post-stop = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            <literal>post-stop</literal> is run in the host's namespace when
            the container enters state <literal>stopped</literal>. The hook's
            exit status is not evaluated.
          '';
        };
      };
    };

    config = mkMerge [
      (mkIf options.config.isDefined {
        path = config.config.system.build.toplevel;
      })
    ];
  };
in
{
  type = container;
  mkServices = mkServices;
}
