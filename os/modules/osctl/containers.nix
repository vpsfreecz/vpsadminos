{ config, lib, pkgs, utils, shared, ... }:
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

  mkService = pool: name: cfg: (
    let
      osctl = "${pkgs.osctl}/bin/osctl";
      osctlPool = "${osctl} --pool ${pool}";
      toplevel = cfg.path;
      closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };

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
        distribution = "nixos";
        version = "18.09";
        arch = "${toString (head (splitString "-" system))}";
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
        apparmor_profile = nullIfEmpty cfg.apparmor;
      };
      
      yml = pkgs.writeText "container-${name}.yml" (builtins.toJSON conf);
      
    in {
      run = ''
        ${osctl} pool show ${pool} &> /dev/null
        hasPool=$?
        if [ "$hasPool" != "0" ] ; then
          echo "Waiting for pool ${pool}"
          exit 1
        fi
        
        ${osctlPool} user show ${cfg.user} &> /dev/null
        hasUser=$?
        if [ "$hasUser" != "0" ] ; then
          echo "Waiting for user ${pool}:${cfg.user}"
          exit 1
        fi
        
        ${osctlPool} group show ${cfg.group} &> /dev/null
        hasGroup=$?
        if [ "$hasGroup" != "0" ] ; then
          echo "Waiting for group ${pool}:${cfg.group}"
          exit 1
        fi

        mkdir -p /nix/var/nix/profiles/per-container
        mkdir -p /nix/var/nix/gcroots/per-container

        ln -sf ${toplevel} /nix/var/nix/profiles/per-container/${name}
        ln -sf ${toplevel} /nix/var/nix/gcroots/per-container/${name}
        
        ${osctlPool} ct show ${name} &> /dev/null
        hasCT=$?
        if [ "$hasCT" == "0" ] ; then
          echo "Container ${pool}:${name} already exists"
          lines=( $(${osctlPool} ct show -H -o rootfs,state,user,group,org.vpsadminos.osctl:config ${name}) )
          if [ "$?" != 0 ] ; then
            echo "Unable to get the container's status"
            exit 1
          fi

          rootfs="''${lines[0]}"
          currentState="''${lines[1]}"
          currentUser="''${lines[2]}"
          currentGroup="''${lines[3]}"
          currentConfig="''${lines[4]}"

          if [ "${cfg.user}" != "$currentUser" ] \
             || [ "${cfg.group}" != "$currentGroup" ] \
             || [ "${yml}" != "$currentConfig" ] ; then
            echo "Reconfiguring the container"

            if [ "$currentState" != "stopped" ] ; then
              ${osctlPool} ct stop ${name}
              originalState="$currentState"
              currentState="stopped"
            fi

            if [ "${cfg.user}" != "$currentUser" ] ; then
              echo "Changing user from $currentUser to ${cfg.user}"
              ${osctlPool} ct chown ${name} ${cfg.user} || exit 1
            fi

            if [ "${cfg.group}" != "$currentGroup" ] ; then
              echo "Changing group from $currentGroup to ${cfg.group}"
              ${osctlPool} ct chgrp ${name} ${cfg.group} || exit 1
            fi

            if [ "${yml}" != "$currentConfig" ] ; then
              echo "Replacing config"
              cat ${yml} | ${osctlPool} ct config replace ${name} || exit 1
              ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:config ${yml}
              ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:declarative yes
            fi
          fi

        else
          echo "Creating container '${name}'"

          ${optionalString (cfg.hooks.pre-create != null) ''
            echo "Executing pre-create script hook"
            ${hookCaller "pre-create" cfg.hooks.pre-create}
            preStartStatus=$?
            case $preStartStatus in
              0) ;;
              2)
                echo "pre-create hook exited with 2, aborting"
                sv once ct-${pool}-${name}
                exit 1
                ;;
              *)
                echo "pre-create hook exited with $preStartStatus, restarting"
                exit 1
                ;;
            esac
          ''}

          ${osctlPool} ct new \
                              --user ${cfg.user} \
                              --group ${cfg.group} \
                              --distribution nixos \
                              --version ${conf.version} \
                              --arch ${conf.arch} \
                              --skip-template \
                              ${name} || exit 1

          cat ${yml} | ${osctlPool} ct config replace ${name} || exit 1
          ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:declarative yes
          ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:config ${yml}

          rootfs="$(${osctlPool} ct show -H -o rootfs ${name})"
          mkdir "$rootfs/dev" "$rootfs/etc" "$rootfs/proc" "$rootfs/run" \
                "$rootfs/sbin" "$rootfs/sys"
          ln -sf /nix/var/nix/profiles/system "$rootfs/run/current-system"
          ln -sf "${toplevel}/init" "$rootfs/sbin/init"

          createdContainer=y
        fi

        echo "Populating /nix/store"
        mkdir -p "$rootfs/nix/store" \
                 "$rootfs/nix/var/nix/gcroots" \
                 "$rootfs/nix/var/nix/profiles"

        ln -sf /run/current-system "$rootfs/nix/var/nix/gcroots/current-system"

        count=$(cat ${closureInfo}/store-paths | wc -l)
        i=1

        for storePath in $(cat ${closureInfo}/store-paths) ; do
          dst="$rootfs/''${storePath:1}"

          if [ -e "$dst" ] ; then
            echo "[$i/$count] Found $storePath"

          else
            echo "[$i/$count] Copying $storePath"
            cp -a $storePath $dst
          fi
          
          i=$(($i+1))
        done

        echo "Installing user script hooks"
        lines=( $(zfs get -Hp -o value mountpoint,org.vpsadminos.osctl:dataset ${pool}) )
        mountpoint="''${lines[0]}"
        osctlDataset="''${lines[1]}"

        [ "$osctlDataset" != "-" ] \
          && mountpoint="$(zfs get -Hp -o value mountpoint $osctlDataset)"

        hookDir="$mountpoint/hook/ct/${name}"

        rm -f "$hookDir/*"
        ${hooks}

        currentSystem=$(realpath "$rootfs/nix/var/nix/profiles/system")

        if [ "$?" != "0" ] || [ "$currentSystem" != "${toplevel}" ] ; then
          echo "Configuring current system"
          cat ${closureInfo}/registration >> "$rootfs/nix-path-registration"
          ln -sf ${toplevel} "$rootfs/nix/var/nix/profiles/system"
          ln -sf ${toplevel}/init "$rootfs/sbin/init"
          
          if [ "$currentState" == "running" ] ; then
            echo "Switching to ${toplevel}"
            ${osctlPool} ct exec ${name} ${toplevel}/bin/switch-to-configuration switch
          fi

        else
          echo "System up-to-date"
        fi

        if [ "$createdContainer" == "y" ] ; then
          ${optionalString (cfg.hooks.on-create != null) ''
            echo "Executing on-create script hook"
            ${hookCaller "on-create" cfg.hooks.on-create}
          ''}
        fi

        if [ "$originalState" == "running" ] \
           || ${boolToStr (cfg.autostart != null)} ; then
          echo "Starting container ${pool}:${name}"
          ${osctlPool} ct start ${name}
        fi

        if [ "$createdContainer" == "y" ] ; then
          ${optionalString (cfg.hooks.post-create != null) ''
            echo "Executing post-create script hook"
            ${hookCaller "post-create" cfg.hooks.post-create}
          ''}
        fi

        sv once ct-${pool}-${name}
      '';

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

      apparmor = mkOption {
        type = types.str;
        default = "";
        example = "osctl-ct-default";
        description = "Name of AppArmor profile";
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
