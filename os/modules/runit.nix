{ lib, config, pkgs, ... }:
with lib;

let
  service = {
    options = {
      runlevels = mkOption {
        type = types.listOf types.str;
        default = [ "default" ];
        description = "Runlevels the service is started in.";
      };

      run = mkOption {
        type = types.str;
        description = "Called to start the service.";
      };

      check = mkOption {
        type = types.str;
        default = "";
        description = "Called to check service status.";
      };

      onChange = mkOption {
        type = types.enum [ "restart" "reload" "ignore" ];
        default = "restart";
        description = ''
          The action switch-to-configuration should perform when the service is
          changed.
        '';
      };

      reloadMethod = mkOption {
        type = types.str;
        default = "reload";
        description = ''
          Defines how should the service be reloaded. The value is the command
          given to runit's sv. See man sv(8) for available options.
        '';
      };

      log = {
        enable = mkEnableOption "Start svlogd for the service.";

        logStandardError = mkOption {
          type = types.bool;
          default = true;
          description = "Log messages the service writes to stderr.";
        };

        run = mkOption {
          type = types.str;
          default = "";
          description = "Called to start log service.";
        };

        maxFileSize = mkOption {
          type = types.ints.unsigned;
          default = 1000000;
          description = ''
            Sets the maximum file size of current when svlogd should rotate
            the current log file to size bytes. Default is 1000000. If fileSize
            is zero, svlogd doesn’t rotate log files.
          '';
        };

        logFiles = mkOption {
          type = types.ints.unsigned;
          default = 10;
          description = ''
            Sets the number of old log files svlogd should maintain.
            If svlogd sees more old log files in log after log file rotation,
            it deletes the oldest one. Default is 10. If set to zero, svlogd
            doesn’t remove old log files.
          '';
        };

        minLogFiles = mkOption {
          type = types.ints.unsigned;
          default = 0;
          description = ''
            Sets the minimum number of old log files svlogd should maintain.
            It must be less than logFiles. If it is set, and svlogd cannot
            write to current because the filesystem is full, and it sees more
            than minLogFiles old log files, it deletes the oldest one.
          '';
        };

        timeout = mkOption {
          type = types.ints.unsigned;
          default = 0;
          description = ''
            Sets the maximum age of the current log file when svlogd should
            rotate the current log file to timeout seconds. If current is
            timeout seconds old, and is not empty, svlogd forces log file
            rotation.
          '';
        };

        sendTo = mkOption {
          type = types.str;
          default = "";
          example = "a.b.c.d[:port]";
          description = ''
            Tells svlogd to transmit the first len characters of selected log
            messages to the IP address a.b.c.d, port number port. If port
            isn’t set, the default port for syslog is used (514). len can be
            set through the -l option, see below. If svlogd has trouble
            sending udp packets, it writes error messages to the log directory.

            Attention: logging through udp is unreliable, and should be used
            in private networks only.
          '';
        };

        sendOnly = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Send messages only via UDP, don't store them in the log directory.
          '';
        };

        linePrefix = mkOption {
          type = types.str;
          default = "";
          description = ''
            Tells svlogd to prefix each line to be written to the log
            directory, to standard error, or through UDP.
          '';
        };
      };
    };
  };

  mkScript = name: script: pkgs.writeScript name
    ''
    #!${pkgs.stdenv.shell}
    ${script}
    '';

  mkStage = type: script: mkScript "runit-stage-${type}" script;

  mkService = name: type: script: mkScript "sv-${name}-${type}" script;

  mkServiceRun = name: service:
    mkService name "run" ''
      ${optionalString (service.log.enable && service.log.logStandardError) "exec 2>&1"}
      ${service.run}
    '';

  mkLogRun = name: service:
    if service.log.run == "" then ''
      mkdir -p /var/log/${name}
      chown log /var/log/${name}
      ln -sf ${mkLogConfig name service} /var/log/${name}/config
      exec chpst -ulog svlogd -tt /var/log/${name}
    '' else service.log.run;

  mkLogConfig = name: service:
    pkgs.writeText "sv-${name}-log-config" ''
      s${toString service.log.maxFileSize}
      n${toString service.log.logFiles}
      ${optionalString (service.log.minLogFiles > 0) "N${toString service.log.minLogFiles}"}
      ${optionalString (service.log.timeout > 0) "t${toString service.log.timeout}"}
      ${optionalString (service.log.sendTo != "") "${if service.log.sendOnly then "U" else "u"}${service.log.sendTo}"}
      ${optionalString (service.log.linePrefix != "") "p${service.log.linePrefix}"}
    '';

  runlevels = lib.unique (lib.flatten (mapAttrsToList (name: service: service.runlevels) config.runit.services));

  runlevelServices = rv: lib.remove null (mapAttrsToList (name: service:
    if elem rv service.runlevels then
      name
    else
      null
  ) config.runit.services);

  mkServices = mkMerge (mapAttrsToList (name: service:
    mkMerge [
      {
        "runit/services/${name}/run".source = mkServiceRun name service;
      }

      (mkIf (service.check != "") {
        "runit/services/${name}/check".source = mkService name "check" service.check;
      })

      (mkIf (service.log.enable) {
        "runit/services/${name}/log/run".source = mkService name "log-run" (mkLogRun name service);
      })
    ]
  ) config.runit.services);

  mkRunlevels = mkMerge (flatten (map (rv:
    map (name:
      { "runit/runsvdir/${rv}/${name}".source = "/etc/runit/services/${name}"; }
    ) (runlevelServices rv)
  ) runlevels));

  mkEnvironment = mkMerge [mkServices mkRunlevels];

in

{
  ### Interface
  options = {
    runit.stage1 = mkOption {
      type = types.str;
      description = ''
        runit runs /etc/runit/1 and waits for it to terminate. The system’s one
        time tasks are done here. /etc/runit/1 has full control of /dev/console
        to be able to start an emergency shell if the one time initialization
        tasks fail. If /etc/runit/1 crashes, or exits 100, runit will skip
        stage 2 and enter stage 3.  
      '';
    };

    runit.stage2 = mkOption {
      type = types.str;
      description = ''
        runit runs /etc/runit/2, which should not return until system shutdown;
        if it crashes, or exits 111, it will be restarted. Normally /etc/runit/2
        starts runsvdir(8). runit is able to handle the ctrl-alt-del keyboard
        request in stage 2.
      '';
    };

    runit.stage3 = mkOption {
      type = types.str;
      description = ''
        If runit is told to shutdown the system, or stage 2 returns, it
        terminates stage 2 if it is running, and runs /etc/runit/3. The systems
        tasks to shutdown and possibly halt or reboot the system are done here.
        If stage 3 returns, runit checks if the file /etc/runit/reboot exists
        and has the execute by owner permission set. If so, the system
        is rebooted, it’s halted otherwise.
      '';
    };

    runit.defaultRunlevel = mkOption {
      type = types.str;
      default = "default";
      description = "Name of a runlevel that is entered by default on boot.";
    };

    runit.services = mkOption {
      type = types.attrsOf (types.submodule service);
      default = {};
      example = literalExample "";
      description = "System services";
    };
  };

  ### Implementation
  config = mkMerge [
    {
      users.extraUsers.log = {
        uid = 497;
      };

      environment.etc = {
        "runit/1".source = mkStage "1" config.runit.stage1;
        "runit/2".source = mkStage "2" config.runit.stage2;
        "runit/3".source = mkStage "3" config.runit.stage3;
      };
    }

    (mkIf (config.runit.services != {}) {
      environment.etc = mkEnvironment;
    })
  ];
}
