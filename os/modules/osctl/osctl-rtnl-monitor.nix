{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osctl.rtnlMonitor;
  stateDir = "/run/osctl-rtnl-monitor";
  rootsFile = "${stateDir}/roots.json";
  s = cfg.settings;
  integerOption =
    min: max: default: description:
    lib.mkOption {
      type = lib.types.ints.between min max;
      inherit default description;
    };
  arguments = lib.escapeShellArgs [
    "--roots-file"
    rootsFile
    "--metrics-file"
    s.metricsFile
    "--interval-ms"
    (toString s.intervalMs)
    "--wait-ms"
    (toString s.waitMs)
    "--min-vps"
    (toString s.minVps)
    "--confirm-frames"
    (toString s.confirmFrames)
    "--max-pending"
    (toString s.maxPending)
    "--max-roots"
    (toString s.maxRoots)
    "--mapping-max-age-ms"
    (toString s.mappingMaxAgeMs)
    "--stacks"
    s.stacks
  ];
in
{
  options.osctl.rtnlMonitor = {
    enable = lib.mkEnableOption "diagnostic RTNL waiter monitoring";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.osctl-rtnl-monitor.override { kernel = config.boot.kernelPackage; };
      defaultText = lib.literalExpression "pkgs.osctl-rtnl-monitor.override { kernel = config.boot.kernelPackage; }";
      description = "Monitor and BPF object built together for the selected kernel.";
    };
    inventoryRefreshInterval =
      integerOption 1 60 5
        "Seconds between successful or failed inventory refresh attempts.";
    settings = {
      intervalMs = integerOption 100 2000 1000 "Snapshot interval in milliseconds.";
      waitMs = integerOption 1 600000 1000 "Minimum pending acquisition-call age in milliseconds.";
      minVps = integerOption 1 1024 3 "Distinct current container roots required for a diagnostic alarm.";
      confirmFrames = integerOption 1 1000 2 "Successive valid frames required for an alarm.";
      maxPending = integerOption 1 65536 4096 "Fixed pending-task map capacity.";
      maxRoots = integerOption 1 1024 1024 "Maximum registered container roots.";
      mappingMaxAgeMs = integerOption 100 3600000 30000 "Maximum inventory age in milliseconds.";
      stacks = lib.mkOption {
        type = lib.types.enum [
          "entry"
          "off"
        ];
        default = "entry";
        description = "Bounded entry-time kernel stack sampling, or disabled sampling.";
      };
      metricsFile = lib.mkOption {
        type = lib.types.strMatching "/[^\n]+";
        default = "/run/metrics/osctl-rtnl-monitor.prom";
        description = "Absolute textfile path exclusively owned by this monitor; removed on clean service exit.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.enableUnifiedCgroupHierarchy;
        message = "osctl.rtnlMonitor requires the unified cgroup-v2 hierarchy.";
      }
    ];
    environment.systemPackages = [ cfg.package ];

    runit.services.osctl-rtnl-monitor-roots = {
      run = ''
        waitForService osctld
        ${pkgs.coreutils}/bin/install -d -m 0700 ${stateDir}
        exec 2>&1
        exec ${cfg.package}/bin/osctl-rtnl-monitor-roots \
          --output ${rootsFile} \
          --refresh-ms ${toString (cfg.inventoryRefreshInterval * 1000)} \
          --max-roots ${toString s.maxRoots}
      '';
      finish = ''
        ${pkgs.coreutils}/bin/rm -f -- ${rootsFile}
        ${pkgs.coreutils}/bin/rmdir -- ${stateDir} 2>/dev/null || true
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
    runit.services.osctl-rtnl-monitor = {
      run = ''
        waitForService osctl-rtnl-monitor-roots
        ${pkgs.coreutils}/bin/mkdir -p -- ${lib.escapeShellArg (builtins.dirOf s.metricsFile)}
        exec 2>&1
        exec ${cfg.package}/bin/osctl-rtnl-monitor ${arguments}
      '';
      finish = ''
        ${pkgs.coreutils}/bin/rm -f -- ${lib.escapeShellArg s.metricsFile}
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
