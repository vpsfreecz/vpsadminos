{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.networking.firewall;

  inherit (config.boot.kernelPackages) kernel;

  kernelHasRPFilter =
    ((kernel.config.isEnabled or (x: false)) "IP_NF_MATCH_RPFILTER")
    || (kernel.features.netfilterRPFilter or false);

  firewallKernelModules = [
    "nf_conntrack"
    "nf_tables"
    "nft_compat"
    "nft_ct"
    "xt_comment"
    "xt_pkttype"
    "xt_tcpudp"
  ]
  ++ optional cfg.conntrack.enable "xt_conntrack"
  ++ optional (!cfg.conntrack.enable) "xt_CT"
  ++ optionals (cfg.checkReversePath != false && kernelHasRPFilter) (
    [
      "ipt_rpfilter"
    ]
    ++ optional config.networking.enableIPv6 "ip6t_rpfilter"
  )
  ++ optionals cfg.rejectPackets (
    [
      "ipt_REJECT"
    ]
    ++ optional config.networking.enableIPv6 "ip6t_REJECT"
  )
  ++ optional (cfg.logRefusedConnections || cfg.logRefusedPackets || cfg.logReversePathDrops) "xt_LOG"
  ++ optional (cfg.pingLimit != null) "xt_limit";

  portRange = types.submodule {
    options = {
      from = mkOption {
        type = types.port;
        description = "First port in the range.";
      };

      to = mkOption {
        type = types.port;
        description = "Last port in the range.";
      };
    };
  };

  protectedRule = types.submodule {
    options = {
      protocol = mkOption {
        type = types.enum [
          "tcp"
          "udp"
        ];
        description = "Protocol to protect.";
      };

      ports = mkOption {
        type = types.listOf types.port;
        default = [ ];
        description = "Ports protected by this rule.";
      };

      portRanges = mkOption {
        type = types.listOf portRange;
        default = [ ];
        description = "Port ranges protected by this rule.";
      };

      allowedIPv4Ranges = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPv4 source ranges allowed to access the protected ports.";
      };

      allowedIPv6Ranges = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPv6 source ranges allowed to access the protected ports.";
      };

      interfaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Limit this protection rule to selected input interfaces.";
      };

      comment = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional iptables comment for generated rules.";
      };
    };
  };

  writeShScript =
    name: text:
    let
      dir = pkgs.writeScriptBin name ''
        #! ${pkgs.runtimeShell} -e
        ${text}
      '';
    in
    "${dir}/bin/${name}";

  commonShell = ''
    ip46tables() {
      iptables -w "$@"
      ${optionalString config.networking.enableIPv6 ''
        ip6tables -w "$@"
      ''}
    }

    ip46tables_ignore() {
      iptables -w "$@" 2>/dev/null || true
      ${optionalString config.networking.enableIPv6 ''
        ip6tables -w "$@" 2>/dev/null || true
      ''}
    }

    remove_notrack_rules() {
      for chain in PREROUTING OUTPUT; do
        while iptables -w -t raw -D "$chain" -m comment --comment nixos-fw-notrack -j CT --notrack 2>/dev/null; do :; done
        ${optionalString config.networking.enableIPv6 ''
          while ip6tables -w -t raw -D "$chain" -m comment --comment nixos-fw-notrack -j CT --notrack 2>/dev/null; do :; done
        ''}
      done
    }

    add_notrack_rules() {
      remove_notrack_rules

      iptables -w -t raw -I PREROUTING 1 -m comment --comment nixos-fw-notrack -j CT --notrack
      iptables -w -t raw -I OUTPUT 1 -m comment --comment nixos-fw-notrack -j CT --notrack
      ${optionalString config.networking.enableIPv6 ''
        ip6tables -w -t raw -I PREROUTING 1 -m comment --comment nixos-fw-notrack -j CT --notrack
        ip6tables -w -t raw -I OUTPUT 1 -m comment --comment nixos-fw-notrack -j CT --notrack
      ''}
    }

    flush_firewall_chains() {
      ip46tables_ignore -D INPUT -j nixos-fw

      for chain in nixos-fw nixos-fw-accept nixos-fw-log-refuse nixos-fw-refuse; do
        ip46tables_ignore -F "$chain"
        ip46tables_ignore -X "$chain"
      done

      ip46tables_ignore -t mangle -D PREROUTING -j nixos-fw-rpfilter
      ip46tables_ignore -t mangle -F nixos-fw-rpfilter
      ip46tables_ignore -t mangle -X nixos-fw-rpfilter
    }

    remove_drop_rule() {
      ip46tables_ignore -D INPUT -j nixos-drop
      ip46tables_ignore -F nixos-drop
      ip46tables_ignore -X nixos-drop
    }
  '';

  mkComment =
    comment: optionalString (comment != null) "-m comment --comment ${escapeShellArg comment}";

  mkPortArgs =
    rule:
    (map (port: "--dport ${toString port}") rule.ports)
    ++ (map (range: "--dport ${toString range.from}:${toString range.to}") rule.portRanges);

  mkIfaceArgs =
    rule:
    if rule.interfaces == [ ] then
      [ "" ]
    else
      map (iface: "-i ${escapeShellArg iface}") rule.interfaces;

  mkProtectedAllowsForFamily =
    iptables: sources: rule:
    concatMapStringsSep "\n" (
      iface:
      concatMapStringsSep "\n" (
        portArg:
        concatMapStringsSep "\n" (source: ''
          ${iptables} -w -A nixos-fw ${iface} -p ${rule.protocol} -s ${escapeShellArg source} ${portArg} ${mkComment rule.comment} -j nixos-fw-accept
        '') sources
      ) (mkPortArgs rule)
    ) (mkIfaceArgs rule);

  mkProtectedDropsForFamily =
    iptables: rule:
    concatMapStringsSep "\n" (
      iface:
      concatMapStringsSep "\n" (portArg: ''
        ${iptables} -w -A nixos-fw ${iface} -p ${rule.protocol} ${portArg} ${mkComment rule.comment} -j nixos-fw-log-refuse
      '') (mkPortArgs rule)
    ) (mkIfaceArgs rule);

  protectedAllowCommands = concatMapStringsSep "\n" (
    rule:
    concatStringsSep "\n" [
      (mkProtectedAllowsForFamily "iptables" rule.allowedIPv4Ranges rule)
      (optionalString config.networking.enableIPv6 (
        mkProtectedAllowsForFamily "ip6tables" rule.allowedIPv6Ranges rule
      ))
    ]
  ) cfg.protectedRules;

  protectedDropCommands = concatMapStringsSep "\n" (
    rule:
    concatStringsSep "\n" [
      (mkProtectedDropsForFamily "iptables" rule)
      (optionalString config.networking.enableIPv6 (mkProtectedDropsForFamily "ip6tables" rule))
    ]
  ) cfg.protectedRules;

  allowedTCPCommands = concatStrings (
    mapAttrsToList (
      iface: ifaceCfg:
      concatMapStrings (port: ''
        ip46tables -A nixos-fw -p tcp --dport ${toString port} -j nixos-fw-accept ${
          optionalString (iface != "default") "-i ${escapeShellArg iface}"
        }
      '') ifaceCfg.allowedTCPPorts
    ) cfg.allInterfaces
  );

  allowedTCPRangeCommands = concatStrings (
    mapAttrsToList (
      iface: ifaceCfg:
      concatMapStrings (
        range:
        let
          rangeStr = "${toString range.from}:${toString range.to}";
        in
        ''
          ip46tables -A nixos-fw -p tcp --dport ${rangeStr} -j nixos-fw-accept ${
            optionalString (iface != "default") "-i ${escapeShellArg iface}"
          }
        ''
      ) ifaceCfg.allowedTCPPortRanges
    ) cfg.allInterfaces
  );

  allowedUDPCommands = concatStrings (
    mapAttrsToList (
      iface: ifaceCfg:
      concatMapStrings (port: ''
        ip46tables -A nixos-fw -p udp --dport ${toString port} -j nixos-fw-accept ${
          optionalString (iface != "default") "-i ${escapeShellArg iface}"
        }
      '') ifaceCfg.allowedUDPPorts
    ) cfg.allInterfaces
  );

  allowedUDPRangeCommands = concatStrings (
    mapAttrsToList (
      iface: ifaceCfg:
      concatMapStrings (
        range:
        let
          rangeStr = "${toString range.from}:${toString range.to}";
        in
        ''
          ip46tables -A nixos-fw -p udp --dport ${rangeStr} -j nixos-fw-accept ${
            optionalString (iface != "default") "-i ${escapeShellArg iface}"
          }
        ''
      ) ifaceCfg.allowedUDPPortRanges
    ) cfg.allInterfaces
  );

  hasLegacyAllowedPorts = any (
    ifaceCfg:
    ifaceCfg.allowedTCPPorts != [ ]
    || ifaceCfg.allowedTCPPortRanges != [ ]
    || ifaceCfg.allowedUDPPorts != [ ]
    || ifaceCfg.allowedUDPPortRanges != [ ]
  ) (attrValues cfg.allInterfaces);

  createBaseChains = ''
    ip46tables -N nixos-fw-accept
    ip46tables -A nixos-fw-accept -j ACCEPT

    ip46tables -N nixos-fw-refuse
    ${
      if cfg.rejectPackets then
        ''
          ip46tables -A nixos-fw-refuse -p tcp ! --syn -j REJECT --reject-with tcp-reset
          ip46tables -A nixos-fw-refuse -j REJECT
        ''
      else
        ''
          ip46tables -A nixos-fw-refuse -j DROP
        ''
    }

    ip46tables -N nixos-fw-log-refuse
    ${optionalString cfg.logRefusedConnections ''
      ip46tables -A nixos-fw-log-refuse -p tcp --syn -j LOG --log-level info --log-prefix "refused connection: "
    ''}
    ${optionalString (cfg.logRefusedPackets && !cfg.logRefusedUnicastsOnly) ''
      ip46tables -A nixos-fw-log-refuse -m pkttype --pkt-type broadcast \
        -j LOG --log-level info --log-prefix "refused broadcast: "
      ip46tables -A nixos-fw-log-refuse -m pkttype --pkt-type multicast \
        -j LOG --log-level info --log-prefix "refused multicast: "
    ''}
    ip46tables -A nixos-fw-log-refuse -m pkttype ! --pkt-type unicast -j nixos-fw-refuse
    ${optionalString cfg.logRefusedPackets ''
      ip46tables -A nixos-fw-log-refuse \
        -j LOG --log-level info --log-prefix "refused packet: "
    ''}
    ip46tables -A nixos-fw-log-refuse -j nixos-fw-refuse

    ip46tables -N nixos-fw
  '';

  rpfilterRules = optionalString (kernelHasRPFilter && (cfg.checkReversePath != false)) ''
    ip46tables -t mangle -N nixos-fw-rpfilter
    ip46tables -t mangle -A nixos-fw-rpfilter -m rpfilter --validmark ${
      optionalString (cfg.checkReversePath == "loose") "--loose"
    } -j RETURN

    iptables -t mangle -A nixos-fw-rpfilter -p udp --sport 67 --dport 68 -j RETURN
    iptables -t mangle -A nixos-fw-rpfilter -s 0.0.0.0 -d 255.255.255.255 -p udp --sport 68 --dport 67 -j RETURN

    ${optionalString cfg.logReversePathDrops ''
      ip46tables -t mangle -A nixos-fw-rpfilter -j LOG --log-level info --log-prefix "rpfilter drop: "
    ''}
    ip46tables -t mangle -A nixos-fw-rpfilter -j DROP
    ip46tables -t mangle -A PREROUTING -j nixos-fw-rpfilter
  '';

  trustedInterfaceRules = concatMapStrings (iface: ''
    ip46tables -A nixos-fw -i ${escapeShellArg iface} -j nixos-fw-accept
  '') cfg.trustedInterfaces;

  commonIcmpRules = ''
    ${optionalString cfg.allowPing ''
      iptables -w -A nixos-fw -p icmp --icmp-type echo-request ${
        optionalString (cfg.pingLimit != null) "-m limit ${cfg.pingLimit} "
      }-j nixos-fw-accept
    ''}

    ${optionalString config.networking.enableIPv6 ''
      ip6tables -A nixos-fw -p icmpv6 --icmpv6-type redirect -j DROP
      ip6tables -A nixos-fw -p icmpv6 --icmpv6-type 139 -j DROP
      ip6tables -A nixos-fw -p icmpv6 -j nixos-fw-accept
      ip6tables -A nixos-fw -d fe80::/64 -p udp --dport 546 -j nixos-fw-accept
    ''}
  '';

  statefulRules = ''
    ${trustedInterfaceRules}

    ip46tables -A nixos-fw -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept

    ${allowedTCPCommands}
    ${allowedTCPRangeCommands}
    ${allowedUDPCommands}
    ${allowedUDPRangeCommands}
    ${commonIcmpRules}

    ${cfg.extraCommands}

    ip46tables -A nixos-fw -j nixos-fw-log-refuse
  '';

  statelessRules = ''
    ${trustedInterfaceRules}

    ${protectedAllowCommands}
    ${protectedDropCommands}

    ${cfg.extraCommands}

    ip46tables -A nixos-fw -j nixos-fw-accept
  '';

  startScript = writeShScript "firewall-start" ''
    ${commonShell}

    flush_firewall_chains
    remove_notrack_rules
    ${optionalString (!cfg.conntrack.enable) "add_notrack_rules"}

    ${createBaseChains}
    ${rpfilterRules}
    ${if cfg.conntrack.enable then statefulRules else statelessRules}

    ip46tables -A INPUT -j nixos-fw
    remove_drop_rule
  '';

  stopScript = writeShScript "firewall-stop" ''
    ${commonShell}

    remove_drop_rule
    ip46tables_ignore -D INPUT -j nixos-fw
    ip46tables_ignore -t mangle -D PREROUTING -j nixos-fw-rpfilter
    remove_notrack_rules

    ${cfg.extraStopCommands}
  '';

  reloadScript = writeShScript "firewall-reload" ''
    ${commonShell}

    remove_drop_rule
    ip46tables -N nixos-drop
    ip46tables -A nixos-drop -j DROP
    ip46tables -I INPUT 1 -j nixos-drop

    ${cfg.extraStopCommands}

    if ${startScript}; then
      remove_drop_rule
    else
      echo "Failed to reload firewall... Stopping"
      ${stopScript}
      exit 1
    fi
  '';
in
{
  options = {
    networking.firewall = {
      conntrack.enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable conntrack-based stateful firewalling. vpsAdminOS disables
          conntrack in the init network namespace by default.
        '';
      };

      protectedRules = mkOption {
        type = types.listOf protectedRule;
        default = [ ];
        description = ''
          Source-restricted services for the stateless vpsAdminOS firewall.
          Unmatched traffic is accepted by default when conntrack is disabled.
        '';
      };

      extraCommands = mkOption {
        type = types.lines;
        default = "";
        example = "iptables -A INPUT -p icmp -j ACCEPT";
        description = ''
          Additional shell commands executed as part of firewall
          initialisation.
        '';
      };

      extraStopCommands = mkOption {
        type = types.lines;
        default = "";
        example = "iptables -P INPUT ACCEPT";
        description = ''
          Additional shell commands executed as part of firewall shutdown.
        '';
      };
    };
  };

  config = mkIf (cfg.enable && cfg.backend == "iptables") {
    assertions = [
      {
        assertion = cfg.checkReversePath == false || kernelHasRPFilter;
        message = "This kernel does not support rpfilter";
      }
    ]
    ++ (map (rule: {
      assertion = rule.ports != [ ] || rule.portRanges != [ ];
      message = "networking.firewall.protectedRules entries must set ports or portRanges";
    }) cfg.protectedRules);

    warnings = optional (!cfg.conntrack.enable && hasLegacyAllowedPorts) ''
      networking.firewall.allowedTCPPorts/allowedUDPPorts are ignored when
      networking.firewall.conntrack.enable is false; use
      networking.firewall.protectedRules for source-restricted services.
    '';

    networking.firewall.checkReversePath = mkIf (!kernelHasRPFilter) (mkDefault false);
    networking.firewall.logRefusedConnections = mkDefault false;

    environment.systemPackages = [ pkgs.nixos-firewall-tool ];

    boot.kernelModules = firewallKernelModules;

    runit.services.firewall = {
      path = [ cfg.package ] ++ cfg.extraPackages;

      run = ''
        ensureServiceStarted eudev-trigger
        waitForService kernel-modules 60 || exit 1
        ${startScript} || exit 1
        exec sleep inf
      '';

      control.usr1 = ''
        source ./helpers
        waitForService kernel-modules 60 || exit 1
        exec ${reloadScript}
      '';

      control.down = ''
        ${stopScript}
        exit 1 # always fail so that runsv kills the infinite sleep run above
      '';

      onChange = "reload";
      reloadMethod = "1";
      restartTriggers = [ firewallKernelModules ];
    };
  };
}
