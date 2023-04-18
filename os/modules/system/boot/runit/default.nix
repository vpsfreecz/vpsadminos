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

      finish = mkOption {
        type = types.str;
        default = "";
        description = ''
          Called after <option>services.runit.&lt;service&gt;.run</option>
          exits.
        '';
      };

      check = mkOption {
        type = types.str;
        default = "";
        description = "Called to check service status.";
      };

      oneShot = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Oneshot services are used to perform one-time tasks, there are no
          long-running processes monitored by runsv. Oneshot services are not
          restarted after they successfully exit.
        '';
      };

      killMode = mkOption {
        type = types.enum [ "control-group" "process" ];
        default = "control-group";
        description = ''
          Specifies how should processes started by this service be killed.

          If set to <literal>control-group</literal>, all processes are sent
          <literal>SIGTERM</literal>. If set to <literal>process</literal>,
          only the main process receives <literal>SIGTERM</literal>.
        '';
      };

      includeHelpers = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Include helper functions, see <literal>./helpers.sh</literal>.
        '';
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

      control = controlsOptions;

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
          type = types.nullOr types.str;
          default = null;
          description = ''
            Tells svlogd to prefix each line to be written to the log
            directory, to standard error, or through UDP.

            If not set, it is set to include machine hostname and service name.
          '';
        };
      };
    };
  };

  controls = {
    "up" = "u";
    "down" = "d";
    "pause" = "p";
    "continue" = "c";
    "hangup" = "h";
    "alarm" = "a";
    "intr" = "i";
    "quit" = "q";
    "usr1" = "1";
    "usr2" = "2";
    "terminate" = "t";
    "kill" = "k";
    "exit" = "x";
  };

  controlOption = name: mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Override runsv control for ${name}

      If the script exits with <literal>0</literal>, runsv refrains from sending
      the service the corresponding signal. See man runsv(8) for more information.
    '';
  };

  controlsOptions = mapAttrs (name: c: controlOption name) controls;

  helpers = name: pkgs.substituteAll {
    src = ./helpers.sh;
    name = "service-helpers";
    osctl = "${pkgs.osctl}/bin/osctl";
  };

  serviceCGroup = name: "/run/runit/cgroup.service/${name}";

  mkScript = name: script: pkgs.writeScript name
    ''
    #!${pkgs.stdenv.shell}
    ${script}
    '';

  mkStage = type: script: mkScript "runit-stage-${type}" script;

  mkService = name: type: script: mkScript "sv-${name}-${type}" script;

  mkServiceRun = name: service:
    mkService name "run" ''
      mkdir -p "${serviceCGroup name}"
      echo $$ >> "${serviceCGroup name}/cgroup.procs"
      ${optionalString (service.log.enable && service.log.logStandardError) "exec 2>&1"}
      ${optionalString service.includeHelpers "source ./helpers"}
      ${service.run}
      ${optionalString service.oneShot ''
      echo "Service ${name} successfully finished"
      mkdir -p /run/service/${name}
      touch /run/service/${name}/done
      sv once ${name}
      ''}
    '';

  mkServiceCheck = name: service:
    mkService name "check" ''
      test -f "/run/service/${name}/done"
    '';

  killCGroup = pkgs.writeScript "kill-cgroup" ''
    #!${pkgs.stdenv.shell}
    cgroup="$1"
    procs="$cgroup/cgroup.procs"

    [ ! -e "$procs" ] && exit 0

    pids=$(cat "$procs")
    [ -n "$pids" ] && kill -SIGTERM $pids
  '';

  mkServiceFinish = name: service:
    mkService name "finish" ''
      ${optionalString (service.killMode == "control-group") ''
      ${killCGroup} ${serviceCGroup name}
      ''}
      ${service.finish}
    '';

  mkControlScript = name: action: script:
    mkService name "control-${action}" script;

  mkLogRun = name: service:
    if service.log.run == "" then ''
      mkdir -p /var/log/${name}
      chown log /var/log/${name}
      ln -sf ${mkLogConfig name service} /var/log/${name}/config
      exec chpst -ulog svlogd -l 4000 -b 4096 -tt /var/log/${name}
    '' else service.log.run;

  mkLogLinePrefix = name: service:
    if isNull service.log.linePrefix then
      "${config.networking.hostName} ${name} "
    else
      service.log.linePrefix;

  mkLogConfig = name: service:
    pkgs.writeText "sv-${name}-log-config" ''
      s${toString service.log.maxFileSize}
      n${toString service.log.logFiles}
      ${optionalString (service.log.minLogFiles > 0) "N${toString service.log.minLogFiles}"}
      ${optionalString (service.log.timeout > 0) "t${toString service.log.timeout}"}
      ${optionalString (service.log.sendTo != "") "${if service.log.sendOnly then "U" else "u"}${service.log.sendTo}"}
      ${optionalString (service.log.linePrefix != "") "p${mkLogLinePrefix name service}"}
    '';

  runlevels = lib.unique (lib.flatten (mapAttrsToList (name: service: service.runlevels) config.runit.services));

  runlevelServices = rv: lib.remove null (mapAttrsToList (name: service:
    if elem rv service.runlevels then
      name
    else
      null
  ) config.runit.services);

  mkControls = name: service: mapAttrsToList (action: script:
    mkIf (script != null) {
      "runit/services/${name}/control/${controls.${action}}".source =
        mkControlScript name action script;
    }
  ) service.control;

  mkServices = mkMerge (mapAttrsToList (name: service:
    mkMerge ([
      {
        "runit/services/${name}/run".source = mkServiceRun name service;
      }

      (mkIf (service.finish != "" || service.killMode == "control-group") {
        "runit/services/${name}/finish".source = mkServiceFinish name service;
      })

      (mkIf (service.check != "" || service.oneShot) {
        "runit/services/${name}/check".source =
          if service.check != "" then
            mkService name "check" service.check
          else mkServiceCheck name service;
      })

      (mkIf service.includeHelpers {
        "runit/services/${name}/helpers".source = helpers name;
      })

      (mkIf (service.log.enable) {
        "runit/services/${name}/log/run".source = mkService name "log-run" (mkLogRun name service);
      })
    ] ++ (mkControls name service))
  ) config.runit.services);

  mkRunlevels = mkMerge (flatten (map (rv:
    map (name:
      { "runit/runsvdir/${rv}/${name}".source = "/etc/runit/services/${name}"; }
    ) (runlevelServices rv)
  ) runlevels));

  mkEnvironment = mkMerge [mkServices mkRunlevels];

  haltReasonTemplate =
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Enable the halt reason template
          '';
        };

        text = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Text appended to the default reason
          '';
        };

        source = mkOption {
          type = types.path;
          description = ''
            Path of the source file. If it is a text file, its contents are
            appended to the default halt reason. If it is an executable file,
            it is run.
          '';
        };
      };
    };

  mkHaltReason = name: tpl:
    if isNull tpl.text then
      { inherit (tpl) enable source; }
    else {
      inherit (tpl) enable;
      source = pkgs.writeText "halt-reason-${name}" tpl.text;
    };

  mkHaltReasons = tpls: mapAttrs' (k: v: nameValuePair "runit/halt.reason.d/${k}" (mkHaltReason k v)) tpls;

  haltScript = pkgs.substituteAll {
    src = ./halt.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
  };

  haltBin = pkgs.runCommand "halt" {} ''
    mkdir -p $out/bin
    ln -s ${haltScript} $out/bin/halt

    for altname in poweroff reboot ; do
      ln -s halt $out/bin/$altname
    done

    mkdir -p $out/share/man/man8
    ${pkgs.asciidoctor}/bin/asciidoctor \
      -b manpage \
      -D $out/share/man/man8 \
      ${./halt.8.adoc}
  '';
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
      description = "System services";
    };

    runit.halt.reasonTemplates = mkOption {
      type = types.attrsOf (types.submodule haltReasonTemplate);
      default = {};
      description = "Halt reason templates";
    };
  };

  ### Implementation
  config = mkMerge [
    {
      users.users.log = {
        uid = 497;
        group = "log";
      };
      users.groups.log = {};

      environment.etc = {
        "runit/1".source = mkStage "1" config.runit.stage1;
        "runit/2".source = mkStage "2" config.runit.stage2;
        "runit/3".source = mkStage "3" config.runit.stage3;
      };
    }

    (mkIf (config.runit.services != {}) {
      environment.etc = mkEnvironment;
      environment.systemPackages = [ pkgs.svctl haltBin ];
    })

    {
      environment.etc = mkHaltReasons config.runit.halt.reasonTemplates;
    }
  ];
}
