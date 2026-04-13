{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.boot.damon.reclaim;

  boolString = v: if v then "Y" else "N";
in
{
  options.boot.damon.reclaim = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable system-managed DAMON_RECLAIM.

        When enabled, vpsAdminOS programs the DAMON_RECLAIM module parameters
        at runtime and then turns reclaim on.
      '';
    };

    scope = mkOption {
      type = types.enum [
        "global"
        "perNode"
      ];
      default = "global";
      description = ''
        Reclaim scope.

        ``global`` uses one DAMON_RECLAIM scheme for the configured global
        target region. ``perNode`` applies the same policy independently on
        each NUMA node that has matching System RAM.
      '';
    };

    minAge = mkOption {
      type = types.int;
      default = 120000000;
      description = ''
        Cold-region age threshold in microseconds.
      '';
    };

    quota = {
      ms = mkOption {
        type = types.int;
        default = 10;
        description = ''
          Reclaim time budget per reset interval in milliseconds.
        '';
      };

      size = mkOption {
        type = types.int;
        default = 128 * 1024 * 1024;
        description = ''
          Reclaim byte budget per reset interval.
        '';
      };

      resetIntervalMs = mkOption {
        type = types.int;
        default = 1000;
        description = ''
          Quota reset interval in milliseconds.
        '';
      };

      memPressureUs = mkOption {
        type = types.int;
        default = 0;
        description = ''
          PSI memory pressure target in microseconds per reset interval.
        '';
      };

      freeMemRate = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Target system free-memory rate in per-thousand units.
        '';
      };

      freeMemBytes = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Target system free-memory tail in bytes.
        '';
      };

      autotuneFeedback = mkOption {
        type = types.int;
        default = 0;
        description = ''
          User feedback value for DAMON quota auto-tuning.
        '';
      };
    };

    watermarks = {
      intervalUs = mkOption {
        type = types.int;
        default = 5000000;
        description = ''
          Watermark recheck interval in microseconds.
        '';
      };

      high = mkOption {
        type = types.int;
        default = 500;
        description = ''
          High free-memory watermark in per-thousand units.
        '';
      };

      mid = mkOption {
        type = types.int;
        default = 400;
        description = ''
          Mid free-memory watermark in per-thousand units.
        '';
      };

      low = mkOption {
        type = types.int;
        default = 200;
        description = ''
          Low free-memory watermark in per-thousand units.
        '';
      };
    };

    monitorAttrs = {
      sampleIntervalUs = mkOption {
        type = types.int;
        default = 5000;
        description = ''
          DAMON sampling interval in microseconds.
        '';
      };

      aggrIntervalUs = mkOption {
        type = types.int;
        default = 100000;
        description = ''
          DAMON aggregation interval in microseconds.
        '';
      };

      minNrRegions = mkOption {
        type = types.int;
        default = 10;
        description = ''
          Minimum number of monitoring regions.
        '';
      };

      maxNrRegions = mkOption {
        type = types.int;
        default = 1000;
        description = ''
          Maximum number of monitoring regions.
        '';
      };
    };

    monitorRegion = {
      start = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Start physical address of the monitored region. Zero keeps the
          kernel default of the largest System RAM region.
        '';
      };

      end = mkOption {
        type = types.int;
        default = 0;
        description = ''
          End physical address of the monitored region. Zero keeps the kernel
          default of the largest System RAM region.
        '';
      };
    };

    skipAnon = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Skip reclaim of anonymous memory.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.minAge >= 0;
        message = "boot.damon.reclaim.minAge must be non-negative";
      }
      {
        assertion = cfg.quota.ms >= 0;
        message = "boot.damon.reclaim.quota.ms must be non-negative";
      }
      {
        assertion = cfg.quota.size >= 0;
        message = "boot.damon.reclaim.quota.size must be non-negative";
      }
      {
        assertion = cfg.quota.resetIntervalMs >= 0;
        message = "boot.damon.reclaim.quota.resetIntervalMs must be non-negative";
      }
      {
        assertion = cfg.quota.memPressureUs >= 0;
        message = "boot.damon.reclaim.quota.memPressureUs must be non-negative";
      }
      {
        assertion = cfg.quota.freeMemRate >= 0 && cfg.quota.freeMemRate <= 1000;
        message = "boot.damon.reclaim.quota.freeMemRate must be between 0 and 1000";
      }
      {
        assertion = cfg.quota.freeMemBytes >= 0;
        message = "boot.damon.reclaim.quota.freeMemBytes must be non-negative";
      }
      {
        assertion = cfg.quota.autotuneFeedback >= 0;
        message = "boot.damon.reclaim.quota.autotuneFeedback must be non-negative";
      }
      {
        assertion = cfg.watermarks.intervalUs >= 0;
        message = "boot.damon.reclaim.watermarks.intervalUs must be non-negative";
      }
      {
        assertion = cfg.watermarks.high >= 0 && cfg.watermarks.high <= 1000;
        message = "boot.damon.reclaim.watermarks.high must be between 0 and 1000";
      }
      {
        assertion = cfg.watermarks.mid >= 0 && cfg.watermarks.mid <= 1000;
        message = "boot.damon.reclaim.watermarks.mid must be between 0 and 1000";
      }
      {
        assertion = cfg.watermarks.low >= 0 && cfg.watermarks.low <= 1000;
        message = "boot.damon.reclaim.watermarks.low must be between 0 and 1000";
      }
      {
        assertion = cfg.watermarks.high >= cfg.watermarks.mid
          && cfg.watermarks.mid >= cfg.watermarks.low;
        message = "boot.damon.reclaim.watermarks must satisfy high >= mid >= low";
      }
      {
        assertion = cfg.monitorAttrs.sampleIntervalUs >= 0;
        message = "boot.damon.reclaim.monitorAttrs.sampleIntervalUs must be non-negative";
      }
      {
        assertion = cfg.monitorAttrs.aggrIntervalUs > 0;
        message = "boot.damon.reclaim.monitorAttrs.aggrIntervalUs must be greater than zero";
      }
      {
        assertion = cfg.monitorAttrs.sampleIntervalUs <= cfg.monitorAttrs.aggrIntervalUs;
        message = "boot.damon.reclaim.monitorAttrs.sampleIntervalUs must not exceed aggrIntervalUs";
      }
      {
        assertion = cfg.monitorAttrs.minNrRegions >= 3;
        message = "boot.damon.reclaim.monitorAttrs.minNrRegions must be at least 3";
      }
      {
        assertion = cfg.monitorAttrs.maxNrRegions >= cfg.monitorAttrs.minNrRegions;
        message = "boot.damon.reclaim.monitorAttrs.maxNrRegions must be >= minNrRegions";
      }
      {
        assertion = cfg.monitorRegion.start >= 0;
        message = "boot.damon.reclaim.monitorRegion.start must be non-negative";
      }
      {
        assertion = cfg.monitorRegion.end >= 0;
        message = "boot.damon.reclaim.monitorRegion.end must be non-negative";
      }
      {
        assertion = cfg.monitorRegion.end == 0 || cfg.monitorRegion.end > cfg.monitorRegion.start;
        message = "boot.damon.reclaim.monitorRegion.end must be greater than start, or zero";
      }
      {
        assertion = (cfg.monitorRegion.start == 0) == (cfg.monitorRegion.end == 0);
        message = "boot.damon.reclaim.monitorRegion.start and end must either both be zero or both be set";
      }
    ];

    system.requiredKernelConfig = optionals cfg.enable (
      with config.lib.kernelConfig;
      [
        (isEnabled "DAMON")
        (isEnabled "DAMON_PADDR")
        (isEnabled "DAMON_RECLAIM")
      ]
    );

    runit.services.damon-reclaim = {
      path = [
        pkgs.coreutils
        pkgs.kmod
      ];

      run = ''
        set -eu

        params=/sys/module/damon_reclaim/parameters
        target_enabled="${boolString cfg.enable}"

        write_param() {
          name="$1"
          value="$2"
          path="$params/$name"

          current="$(cat "$path")"
          if [ "$current" != "$value" ]; then
            echo "$value" > "$path"
          fi
        }

        if [ ! -d "$params" ] && [ "$target_enabled" = "Y" ]; then
          modprobe damon_reclaim 2>/dev/null || true
        fi

        if [ ! -d "$params" ]; then
          if [ "$target_enabled" = "Y" ]; then
            echo "damon_reclaim parameters not found at $params"
            exit 1
          fi

          exec sleep inf
        fi

        write_param min_age "${toString cfg.minAge}"
        write_param scope "${if cfg.scope == "perNode" then "per-node" else "global"}"
        write_param quota_ms "${toString cfg.quota.ms}"
        write_param quota_sz "${toString cfg.quota.size}"
        write_param quota_reset_interval_ms "${toString cfg.quota.resetIntervalMs}"
        write_param quota_mem_pressure_us "${toString cfg.quota.memPressureUs}"
        write_param quota_free_mem_rate "${toString cfg.quota.freeMemRate}"
        write_param quota_free_mem_bytes "${toString cfg.quota.freeMemBytes}"
        write_param quota_autotune_feedback "${toString cfg.quota.autotuneFeedback}"
        write_param wmarks_interval "${toString cfg.watermarks.intervalUs}"
        write_param wmarks_high "${toString cfg.watermarks.high}"
        write_param wmarks_mid "${toString cfg.watermarks.mid}"
        write_param wmarks_low "${toString cfg.watermarks.low}"
        write_param sample_interval "${toString cfg.monitorAttrs.sampleIntervalUs}"
        write_param aggr_interval "${toString cfg.monitorAttrs.aggrIntervalUs}"
        write_param min_nr_regions "${toString cfg.monitorAttrs.minNrRegions}"
        write_param max_nr_regions "${toString cfg.monitorAttrs.maxNrRegions}"
        write_param monitor_region_start "${toString cfg.monitorRegion.start}"
        write_param monitor_region_end "${toString cfg.monitorRegion.end}"
        write_param skip_anon "${boolString cfg.skipAnon}"

        current_enabled="$(cat "$params/enabled")"

        if [ "$target_enabled" = "Y" ]; then
          if [ "$current_enabled" = "Y" ]; then
            echo Y > "$params/commit_inputs"
          else
            echo Y > "$params/enabled"
          fi
        elif [ "$current_enabled" != "N" ]; then
          echo N > "$params/enabled"
        fi

        exec sleep inf
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
