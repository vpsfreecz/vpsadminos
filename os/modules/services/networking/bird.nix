{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.bird2;
in {
  options = {
    services.bird2 = {
      enable = mkEnableOption "BIRD Internet Routing Daemon";
      config = mkOption {
        type = types.lines;
        description = ''
          BIRD Internet Routing Daemon configuration file.
          <link xlink:href='http://bird.network.cz/'/>
        '';
      };
      checkConfig = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the config should be checked at build time.
          When the config can't be checked during build time, for example when it includes
          other files, either disable this option or use <code>preCheckConfig</code> to create
          the included files before checking.
        '';
      };
      preCheckConfig = mkOption {
        type = types.lines;
        default = "";
        example = ''
          echo "cost 100;" > include.conf
        '';
        description = ''
          Commands to execute before the config file check. The file to be checked will be
          available as <code>bird2.conf</code> in the current directory.
          Files created with this option will not be available at service runtime, only during
          build time checking.
        '';
      };
      preStartCommands = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Commands executed before the bird daemon is started
        '';
      };
      user = mkOption {
        type = types.str;
        default = "bird2";
        readOnly = true;
        description = ''
          User the bird daemon runs as
        '';
      };
      group = mkOption {
        type = types.str;
        default = "bird2";
        readOnly = true;
        description = ''
          Group the bird daemon runs as
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.bird ];

    environment.etc."bird2.conf".source = pkgs.writeTextFile {
      name = "bird2";
      text = cfg.config;
      checkPhase = optionalString cfg.checkConfig ''
        ln -s $out bird2.conf
        ${cfg.preCheckConfig}
        ${pkgs.bird}/bin/bird -d -p -c bird2.conf
      '';
    };

    runit.services.bird2 = {
      run = ''
        mkdir -p -m 0750 /run/bird
        chmod 0750 /run/bird
        chown ${cfg.user}:${cfg.group} /run/bird
        ${cfg.preStartCommands}
        exec ${pkgs.bird}/bin/bird -c /etc/bird2.conf -u ${cfg.user} -g ${cfg.group} -f
      '';
      runlevels = [ "rescue" "default" ];
      onChange = mkDefault "ignore";
    };

    users = {
      users.${cfg.user} = {
        isSystemUser = true;
        description = "BIRD Internet Routing Daemon user";
        group = cfg.group;
      };
      groups.${cfg.group} = {};
    };
  };
}
