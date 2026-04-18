{
  config,
  lib,
  pkgs,
  options,
}:

with lib;

let
  cfg = config.services.prometheus.exporters.zfs;

  defaultPoolProperties = [
    "allocated"
    "dedupratio"
    "fragmentation"
    "free"
    "freeing"
    "health"
    "leaked"
    "readonly"
    "size"
  ];

  defaultFilesystemProperties = [
    "available"
    "compressratio"
    "logicalreferenced"
    "logicalused"
    "quota"
    "referenced"
    "refcompressratio"
    "refquota"
    "reservation"
    "refreservation"
    "used"
    "usedbychildren"
    "usedbydataset"
    "usedbyrefreservation"
    "usedbysnapshots"
    "written"
  ];

  defaultVolumeProperties = [
    "available"
    "compressratio"
    "logicalreferenced"
    "logicalused"
    "referenced"
    "refcompressratio"
    "reservation"
    "refreservation"
    "used"
    "usedbydataset"
    "usedbyrefreservation"
    "usedbysnapshots"
    "volsize"
    "written"
  ];

  defaultSnapshotProperties = [
    "logicalused"
    "referenced"
    "used"
    "written"
  ];

  mkCollectorFlag =
    name: enabled: if enabled then "--collector.${name}" else "--no-collector.${name}";

  mkPropertiesFlag =
    name: properties: "--properties.${name}=${escapeShellArg (concatStringsSep "," properties)}";
in
{
  user = "root";
  group = "root";
  port = 9134;

  extraOpts = {
    package = mkOption {
      type = types.package;
      default = pkgs.prometheus-zfs-exporter;
      defaultText = literalExpression "pkgs.prometheus-zfs-exporter";
      description = lib.mdDoc ''
        Package providing the <command>zfs_exporter</command> executable.
      '';
    };

    zfsPackage = mkOption {
      type = types.package;
      default = config.boot.zfsUserPackage;
      defaultText = literalExpression "config.boot.zfsUserPackage";
      description = lib.mdDoc ''
        ZFS userland package that provides the <command>zfs</command> and
        <command>zpool</command> commands used by the exporter.
      '';
    };

    telemetryPath = mkOption {
      type = types.str;
      default = "/metrics";
      description = lib.mdDoc ''
        HTTP path under which ZFS metrics are exposed.
      '';
    };

    webConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = lib.mdDoc ''
        Path to an exporter-toolkit web configuration file that can enable TLS
        or authentication.
      '';
    };

    deadline = mkOption {
      type = types.str;
      default = "8s";
      example = "5s";
      description = lib.mdDoc ''
        Maximum duration of a single collection before cached data is returned.
      '';
    };

    pools = mkOption {
      type = types.listOf types.str;
      default = attrNames config.boot.zfs.pools;
      defaultText = literalExpression "lib.attrNames config.boot.zfs.pools";
      example = [
        "rpool"
        "tank"
      ];
      description = lib.mdDoc ''
        Names of ZFS pools to collect. When empty, the exporter default is used
        and all imported pools are collected.
      '';
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "^tank/tmp/" ];
      description = lib.mdDoc ''
        Regular expressions for datasets, snapshots, or volumes to exclude.
        Each value becomes a separate <literal>--exclude</literal> flag.
      '';
    };

    collectors = mkOption {
      type = types.submodule {
        options = {
          pool = mkOption {
            type = types.bool;
            default = true;
            description = lib.mdDoc ''
              Collect pool-level metrics.
            '';
          };

          datasetFilesystem = mkOption {
            type = types.bool;
            default = true;
            description = lib.mdDoc ''
              Collect filesystem dataset metrics.
            '';
          };

          datasetVolume = mkOption {
            type = types.bool;
            default = true;
            description = lib.mdDoc ''
              Collect volume dataset metrics.
            '';
          };

          datasetSnapshot = mkOption {
            type = types.bool;
            default = false;
            description = lib.mdDoc ''
              Collect snapshot metrics. This is disabled by default because it
              can create a large number of time series.
            '';
          };
        };
      };
      default = { };
      description = lib.mdDoc ''
        Enabled <command>zfs_exporter</command> collectors.
      '';
    };

    properties = mkOption {
      type = types.submodule {
        options = {
          pool = mkOption {
            type = types.listOf types.str;
            default = defaultPoolProperties;
            description = lib.mdDoc ''
              Pool properties collected by the pool collector.
            '';
          };

          datasetFilesystem = mkOption {
            type = types.listOf types.str;
            default = defaultFilesystemProperties;
            description = lib.mdDoc ''
              Filesystem dataset properties collected by the filesystem dataset
              collector.
            '';
          };

          datasetVolume = mkOption {
            type = types.listOf types.str;
            default = defaultVolumeProperties;
            description = lib.mdDoc ''
              Volume dataset properties collected by the volume dataset
              collector.
            '';
          };

          datasetSnapshot = mkOption {
            type = types.listOf types.str;
            default = defaultSnapshotProperties;
            description = lib.mdDoc ''
              Snapshot properties collected by the snapshot dataset collector.
            '';
          };
        };
      };
      default = { };
      description = lib.mdDoc ''
        ZFS properties collected by each enabled collector.
      '';
    };
  };

  serviceRun = with cfg; ''
    export PATH="${zfsPackage}/bin:$PATH"

    execExporter ${
      concatStringsSep " \\\n        " (
        [
          "${package}/bin/zfs_exporter"
          "--web.listen-address=${listenAddress}:${toString port}"
          "--web.telemetry-path=${escapeShellArg telemetryPath}"
          "--deadline=${escapeShellArg deadline}"
          (mkCollectorFlag "pool" collectors.pool)
          (mkCollectorFlag "dataset-filesystem" collectors.datasetFilesystem)
          (mkCollectorFlag "dataset-volume" collectors.datasetVolume)
          (mkCollectorFlag "dataset-snapshot" collectors.datasetSnapshot)
          (mkPropertiesFlag "pool" properties.pool)
          (mkPropertiesFlag "dataset-filesystem" properties.datasetFilesystem)
          (mkPropertiesFlag "dataset-volume" properties.datasetVolume)
          (mkPropertiesFlag "dataset-snapshot" properties.datasetSnapshot)
        ]
        ++ optionals (webConfigFile != null) [
          "--web.config.file=${escapeShellArg webConfigFile}"
        ]
        ++ map (pool: "--pool=${escapeShellArg pool}") pools
        ++ map (pattern: "--exclude=${escapeShellArg pattern}") exclude
        ++ extraFlags
      )
    }
  '';
}
