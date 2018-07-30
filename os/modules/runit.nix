{ lib, config, pkgs, ... }:
with lib;

let
  service = {
    options = {
      directory = mkOption {
        type = types.str;
        default = "/etc/service";
        description = "Service directory";
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
    };
  };

  svDir = service:
    if hasPrefix "/etc/" service.directory then
      removePrefix "/etc/" service.directory
    else
      service.directory;

  mkScript = name: script: pkgs.writeScript name script;

  mkStage = type: script: mkScript "runit-stage-${type}" script;

  mkService = name: type: script: pkgs.writeScript "sv-${name}-${type}" script;

  mkEnvironment = mkMerge (mapAttrsToList (name: service:
    mkMerge [
      {
        "${svDir service}/${name}/run".source = mkService name "run" service.run;
      }

      (mkIf (service.check != "") {
        "${svDir service}/${name}/check".source = mkService name "check" service.check;
      })
    ]
  ) config.runit.services);

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
