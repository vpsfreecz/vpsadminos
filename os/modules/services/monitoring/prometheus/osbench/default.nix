{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.prometheus.exporters.osbench;

  textfileDirectory = "/run/metrics";

  runner = pkgs.substituteAll {
    src = ./runner.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
  };

  tests = [
    "create_files"
    "create_processes"
    "create_threads"
    "launch_programs"
    "mem_alloc"
  ];

  cronIntervals = {
    # create_files = "*/5 * * * *";
  };

  extraOptions = {
    create_files = {
      testDirectory = mkOption {
        type = types.path;
        default = "/tmp";
        description = ''
          Directory in which test files are created
        '';
      };
    };
  };

  testArgs = {
    create_files = test: ''"${test.testDirectory}"'';
  };

  testCommand = name: test:
    if hasAttr name testArgs then
      "${name} ${testArgs.${name} test}"
    else
      name;

  mkTestModule = name: {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable osbench test ${name}
      '';
    };

    cronInterval = mkOption {
      type = types.str;
      default = cronIntervals.${name} or "*/1 * * * *";
      description = ''
        Date and time expression in a crontab format for when to run the test
      '';
    };
  } // (extraOptions.${name} or {});

  testCronJobs = tests: mapAttrsToList (name: test:
    "${test.cronInterval} root ${runner} ${textfileDirectory} ${pkgs.osbench} ${testCommand name test}"
  ) tests;
in
{
  options = {
    services.prometheus.exporters.osbench = {
      enable = mkEnableOption "Enable osbench exporter";

      tests = listToAttrs (map (test: nameValuePair test (mkTestModule test)) tests);
    };
  };

  config = mkIf cfg.enable {
    services.cron.systemCronJobs = testCronJobs cfg.tests;
  };
}
