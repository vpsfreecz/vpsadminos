{ config, pkgs, lib, options, ... }:

let
  inherit (lib) concatStrings foldl foldl' genAttrs literalExpression maintainers
                mapAttrsToList mkDefault mkEnableOption mkIf mkMerge mkOption
                optional optionalString types mkOptionDefault flip attrNames;

  cfg = config.services.prometheus.exporters;

  # each attribute in `exporterOpts` is expected to have specified:
  #   - user        (types.str):   default system user (optional)
  #   - group       (types.str):   default system group (optional)
  #   - port        (types.int):   port on which the exporter listens
  #   - serviceRun  (types.lines): script fragment to run the exporter
  #   - extraOpts   (types.attrs): extra configuration options to
  #                                configure the exporter with, which
  #                                are appended to the default options
  #
  #  Note that `extraOpts` is optional, but a script for the exporter's
  #  runit service must be provided by specifying `serviceRun`

  exporterOpts = genAttrs [
    "ipmi"
    "ksvcmon"
    "node"
    "osctl"
  ] (name:
    import (./. + "/exporters/${name}.nix") { inherit config lib pkgs options; }
  );

  mkExporterOpts = ({ name, port, user, group }: {
    enable = mkEnableOption (lib.mdDoc "the prometheus ${name} exporter");
    port = mkOption {
      type = types.port;
      default = port;
      description = lib.mdDoc ''
        Port to listen on.
      '';
    };
    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = lib.mdDoc ''
        Address to listen on.
      '';
    };
    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = lib.mdDoc ''
        Extra commandline options to pass to the ${name} exporter.
      '';
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc ''
        Open port in firewall for incoming connections.
      '';
    };
    firewallFilter = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = literalExpression ''
        "-i eth0 -p tcp -m tcp --dport ${toString port}"
      '';
      description = lib.mdDoc ''
        Specify a filter for iptables to use when
        {option}`services.prometheus.exporters.${name}.openFirewall`
        is true. It is used as `ip46tables -I nixos-fw firewallFilter -j nixos-fw-accept`.
      '';
    };
    user = mkOption {
      type = types.str;
      default = user;
      description = lib.mdDoc ''
        User name under which the ${name} exporter shall be run.
      '';
    };
    group = mkOption {
      type = types.str;
      default = group;
      description = lib.mdDoc ''
        Group under which the ${name} exporter shall be run.
      '';
    };
  });

  mkSubModule = { name, port, user, group, extraOpts, imports }: {
    ${name} = mkOption {
      type = types.submodule [{
        inherit imports;
        options = (mkExporterOpts {
          inherit name port user group;
        } // extraOpts);
      } ({ config, ... }: mkIf config.openFirewall {
        firewallFilter = mkDefault "-p tcp -m tcp --dport ${toString config.port}";
      })];
      internal = true;
      default = {};
    };
  };

  mkSubModules = (foldl' (a: b: a//b) {}
    (mapAttrsToList (name: opts: mkSubModule {
      inherit name;
      inherit (opts) port;
      user = opts.user or "${name}-exporter";
      group = opts.group or "${name}-exporter";
      extraOpts = opts.extraOpts or {};
      imports = opts.imports or [];
    }) exporterOpts)
  );

  mkExporterConf = { name, conf, serviceRun }:
    mkIf conf.enable {
      warnings = conf.warnings or [];
      users.users."${name}-exporter" = (mkIf (conf.user == "${name}-exporter") {
        description = "Prometheus ${name} exporter service user";
        isSystemUser = true;
        inherit (conf) group;
      });
      users.groups = (mkIf (conf.group == "${name}-exporter") {
        "${name}-exporter" = {};
      });
      networking.firewall.extraCommands = mkIf conf.openFirewall (concatStrings [
        "ip46tables -A nixos-fw ${conf.firewallFilter} "
        "-m comment --comment ${name}-exporter -j nixos-fw-accept"
      ]);
      runit.services."prometheus-${name}-exporter" = {
        run =
          let
            switchUser = conf.user != "root" || conf.group != "root";
          in ''
            function execExporter {
              exec ${optionalString switchUser "chpst -u ${conf.user}:${conf.group}"} "$@"
            }

            ${serviceRun}
          '';
        log.enable = true;
        log.sendTo = "127.0.0.1";
      };
  };
in
{
  options.services.prometheus.exporters = mkOption {
    type = types.submodule {
      options = (mkSubModules);
      imports = [
        <nixpkgs/nixos/modules/misc/assertions.nix>
      ];
    };
    description = lib.mdDoc "Prometheus exporter configuration";
    default = {};
    example = literalExpression ''
      {
        node = {
          enable = true;
        };
      }
    '';
  };

  config = mkMerge ([{
    assertions = (flip map (attrNames exporterOpts) (exporter: {
      assertion = cfg.${exporter}.firewallFilter != null -> cfg.${exporter}.openFirewall;
      message = ''
        The `firewallFilter'-option of exporter ${exporter} doesn't have any effect unless
        `openFirewall' is set to `true'!
      '';
    })) ++ config.services.prometheus.exporters.assertions;
    warnings = config.services.prometheus.exporters.warnings;
  }] ++ (mapAttrsToList (name: conf:
    mkExporterConf {
      inherit name;
      inherit (conf) serviceRun;
      conf = cfg.${name};
    }) exporterOpts)
  );
}
