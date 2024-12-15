{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.boot.initrd.network;

  dhcpInterfaces = lib.attrNames (lib.filterAttrs (iface: v: v.useDHCP == true) (config.networking.interfaces or {}));

  doDhcp =
    if isNull cfg.useDHCP then
      config.networking.useDHCP || dhcpInterfaces != []
    else
      cfg.useDHCP;

  dhcpIfShellExpr = if config.networking.useDHCP || cfg.useDHCP
                      then "$(ls /sys/class/net/ | grep -v ^lo$ | grep -v ^ip6tnl)"
                      else lib.concatMapStringsSep " " lib.escapeShellArg dhcpInterfaces;

  udhcpcScript = pkgs.writeScript "udhcp-script"
    ''
      #! /bin/sh
      if [ "$1" = bound ]; then
        ip address add "$ip/$mask" dev "$interface"
        if [ -n "$mtu" ]; then
          ip link set mtu "$mtu" dev "$interface"
        fi
        if [ -n "$staticroutes" ]; then
          echo "$staticroutes" \
            | sed -r "s@(\S+) (\S+)@ ip route add \"\1\" via \"\2\" dev \"$interface\" ; @g" \
            | sed -r "s@ via \"0\.0\.0\.0\"@@g" \
            | /bin/sh
        fi
        if [ -n "$router" ]; then
          ip route add "$router" dev "$interface" # just in case if "$router" is not within "$ip/$mask" (e.g. Hetzner Cloud)
          ip route add default via "$router" dev "$interface"
        fi
        if [ -n "$dns" ]; then
          rm -f /etc/resolv.conf
          for server in $dns; do
            echo "nameserver $server" >> /etc/resolv.conf
          done
        fi
      fi
    '';

  udhcpcArgs = toString cfg.udhcpc.extraArgs;

in

{

  options = {

    boot.initrd.network.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add network connectivity support to initrd. The network may be
        configured using the <literal>ip</literal> kernel parameter,
        as described in <link
        xlink:href="https://www.kernel.org/doc/Documentation/filesystems/nfs/nfsroot.txt">the
        kernel documentation</link>.  Otherwise, if
        <option>networking.useDHCP</option> is enabled, an IP address
        is acquired using DHCP.
        You should add the module(s) required for your network card to
        boot.initrd.availableKernelModules.
        <literal>lspci -v | grep -iA8 'network\|ethernet'</literal>
        will tell you which.
      '';
    };

    boot.initrd.network.enableSetupInCrashDump = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable ipconfig/DHCP also within crashdump system, see {option}`boot.crashDump.enable`.
        When disabled, you can use {}`boot.initrd.network.customSetupCommands` to run your
        own commands.
      '';
    };

    boot.initrd.network.flushBeforeStage2 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to clear the configuration of the interfaces that were set up in
        the initrd right before stage 2 takes over. Stage 2 will do the regular network
        configuration based on the NixOS networking options.
      '';
    };

    boot.initrd.network.useDHCP = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Whether to use DHCP in the initrd.
      '';
    };

    boot.initrd.network.preferredDHCPInterfaceMacAddresses = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of network interface MAC addresses that should be tried for DHCP first.
        Use this to run DHCP on specific interfaces first and skip network interfaces
        wouldn't work. If no interface from this is list found or don't work,
        all network interfaces within the system will be tried.
      '';
    };

    boot.initrd.network.udhcpc.extraArgs = mkOption {
      default = [];
      type = types.listOf types.str;
      description = ''
        Additional command-line arguments passed verbatim to udhcpc if
        <option>boot.initrd.network.enable</option> and <option>networking.useDHCP</option>
        are enabled.
      '';
    };

    boot.initrd.network.setClock = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Set clock in initrd using NTP servers in <option>networking.timeServers</option>
      '';
    };

    boot.initrd.network.customSetupCommands = mkOption {
      default = "";
      type = types.lines;
      description = ''
        Shell commands to be executed after stage 1 of the
        boot has initialised the network using DHCP, but before clock is set
        and {option}`boot.initrd.network.postCommands` are run.
      '';
    };

    boot.initrd.network.postCommands = mkOption {
      default = "";
      type = types.lines;
      description = ''
        Shell commands to be executed after stage 1 of the
        boot has initialised the network.
      '';
    };


  };

  config = mkIf cfg.enable {

    boot.initrd.kernelModules = [ "af_packet" ];

    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.klibc}/lib/klibc/bin.static/ipconfig
    '';

    boot.initrd.preLVMCommands = mkBefore (
      # Search for interface definitions in command line.
      ''
        ifaces=""

        if ${if cfg.enableSetupInCrashDump then "true" else "! grep -q this_is_a_crash_kernel /proc/cmdline"}; then
          for o in $(cat /proc/cmdline); do
            case $o in
              ip=*)
                ipconfig $o && ifaces="$ifaces $(echo $o | cut -d: -f6)"
                ;;
            esac
          done
        fi
      ''

      # Otherwise, use DHCP.
      + optionalString doDhcp ''
        if ${if cfg.enableSetupInCrashDump then "true" else "! grep -q this_is_a_crash_kernel /proc/cmdline"}; then
          sleep 3

          runUdhcpc() {
            local iface="$1"

            echo "Acquiring IP address via DHCP on $iface..."
            udhcpc --quit --now -i $iface -t 5 -O staticroutes --script ${udhcpcScript} ${udhcpcArgs}

            if ip route | grep -q "^default"; then
              echo "Default route exists, DHCP successful on $iface"
              return 0
            fi

            return 1
          }

          # Bring up all interfaces
          for iface in ${dhcpIfShellExpr}; do
            echo "Bringing up network interface $iface..."
            ip link set "$iface" up && ifaces="$ifaces $iface"
          done

          touch /.tried-dhcp-interfaces

          ${optionalString (cfg.preferredDHCPInterfaceMacAddresses != []) ''
          # Try preferred interfaces
          for mac in ${concatStringsSep " " cfg.preferredDHCPInterfaceMacAddresses}; do
            iface=$(ip -o link | grep "$mac" | awk -F': ' '{print $2}')

            if [ -n "$iface" ]; then
              echo "$iface" >> /.tried-dhcp-interfaces
              runUdhcpc "$iface" && break
            else
              echo "Preferred interface with $mac not found"
            fi
          done
          ''}

          # Acquire DHCP leases
          if ! ip route | grep -q "^default"; then
            for iface in ${dhcpIfShellExpr}; do
              grep -q -x "$iface" /.tried-dhcp-interfaces && continue
              runUdhcpc "$iface" && break
            done
          fi
        else
          echo "Skipping DHCP in crash kernel"
        fi
      ''

      + cfg.customSetupCommands

      + optionalString cfg.setClock ''
        ntpd -q ${concatMapStringsSep " " (v: "-p ${v}") config.networking.timeServers}
      ''

      + cfg.postCommands);

    boot.initrd.postMountCommands = mkIf cfg.flushBeforeStage2 ''
      for iface in $ifaces; do
        ip address flush "$iface"
        ip link set "$iface" down
      done
    '';

  };

}
