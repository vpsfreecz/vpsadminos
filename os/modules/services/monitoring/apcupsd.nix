{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.apcupsd;

  configFile = pkgs.writeText "apcupsd.conf" ''
    ## apcupsd.conf v1.1 ##
    # apcupsd complains if the first line is not like above.
    ${cfg.configText}
    SCRIPTDIR ${toString scriptDir}
  '';

  # List of events from "man apccontrol"
  eventList = [
    "annoyme"
    "battattach"
    "battdetach"
    "changeme"
    "commfailure"
    "commok"
    "doreboot"
    "doshutdown"
    "emergency"
    "failing"
    "killpower"
    "loadlimit"
    "mainsback"
    "onbattery"
    "offbattery"
    "powerout"
    "remotedown"
    "runlimit"
    "timeout"
    "startselftest"
    "endselftest"
  ];

  shellCmdsForEventScript = eventname: commands: ''
    echo "#!${pkgs.runtimeShell}" > "$out/${eventname}"
    echo '${commands}' >> "$out/${eventname}"
    chmod a+x "$out/${eventname}"
  '';

  eventToShellCmds = event: if builtins.hasAttr event cfg.hooks then (shellCmdsForEventScript event (builtins.getAttr event cfg.hooks)) else "";

  scriptDir = pkgs.runCommand "apcupsd-scriptdir" { preferLocalBuild = true; } (''
    mkdir "$out"
    # Copy SCRIPTDIR from apcupsd package
    cp -r ${pkgs.apcupsd}/etc/apcupsd/* "$out"/
    # Make the files writeable (nix will unset the write bits afterwards)
    chmod u+w "$out"/*
    # Remove the sample event notification scripts, because they don't work
    # anyways (they try to send mail to "root" with the "mail" command)
    (cd "$out" && rm changeme commok commfailure onbattery offbattery)
    # Remove the sample apcupsd.conf file (we're generating our own)
    rm "$out/apcupsd.conf"
    # Set the SCRIPTDIR= line in apccontrol to the dir we're creating now
    sed -i -e "s|^SCRIPTDIR=.*|SCRIPTDIR=$out|" "$out/apccontrol"
    '' + concatStringsSep "\n" (map eventToShellCmds eventList)

  );

in

{

  ###### interface

  options = {

    services.apcupsd = {

      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Whether to enable the APC UPS daemon. apcupsd monitors your UPS and
          permits orderly shutdown of your computer in the event of a power
          failure. User manual: http://www.apcupsd.com/manual/manual.html.
          Note that apcupsd runs as root (to allow shutdown of computer).
          You can check the status of your UPS with the "apcaccess" command.
        '';
      };

      configText = mkOption {
        default = ''
          UPSTYPE usb
          NISIP 127.0.0.1
          BATTERYLEVEL 50
          MINUTES 5
        '';
        type = types.lines;
        description = ''
          Contents of the runtime configuration file, apcupsd.conf. The default
          settings makes apcupsd autodetect USB UPSes, limit network access to
          localhost and shutdown the system when the battery level is below 50
          percent, or when the UPS has calculated that it has 5 minutes or less
          of remaining power-on time. See man apcupsd.conf for details.
        '';
      };

      hooks = mkOption {
        default = {};
        example = {
          doshutdown = ''# shell commands to notify that the computer is shutting down'';
        };
        type = types.attrsOf types.lines;
        description = ''
          Each attribute in this option names an apcupsd event and the string
          value it contains will be executed in a shell, in response to that
          event (prior to the default action). See "man apccontrol" for the
          list of events and what they represent.
          A hook script can stop apccontrol from doing its default action by
          exiting with value 99. Do not do this unless you know what you're
          doing.
        '';
      };

    };

  };


  ###### implementation

  config = mkIf cfg.enable {

    assertions = [ {
      assertion = let hooknames = builtins.attrNames cfg.hooks; in all (x: elem x eventList) hooknames;
      message = ''
        One (or more) attribute names in services.apcupsd.hooks are invalid.
        Current attribute names: ${toString (builtins.attrNames cfg.hooks)}
        Valid attribute names  : ${toString eventList}
      '';
    } ];

    # Give users access to the "apcaccess" tool
    environment.systemPackages = [ pkgs.apcupsd ];

    runit.services.apcupsd = {
      run = ''
        mkdir -p /run/apcupsd
        exec ${pkgs.apcupsd}/bin/apcupsd -b -f ${configFile} -d1
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

  };

}
