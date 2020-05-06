{ config, lib, pkgs, ... }:
with lib;
let
  nodeCfg = config.services.munin-node;

  nodeConf = pkgs.writeText "munin-node.conf"
    ''
      log_level 3
      log_file Sys::Syslog
      port 4949
      host *
      background 0
      user root
      group root
      host_name ${config.networking.hostName}
      setsid 0
      # wrapped plugins by makeWrapper being with dots
      ignore_file ^\.
      allow ^::1$
      allow ^127\.0\.0\.1$
      ${nodeCfg.extraConfig}
    '';

  pluginConf = pkgs.writeText "munin-plugin-conf"
    ''
      [hddtemp_smartctl]
      user root
      group root
      [meminfo]
      user root
      group root
      [ipmi*]
      user root
      group root
      [munin*]
      env.UPDATE_STATSFILE /var/lib/munin/munin-update.stats
      ${nodeCfg.extraPluginConfig}
    '';

  pluginConfDir = pkgs.stdenv.mkDerivation {
    name = "munin-plugin-conf.d";
    buildCommand = ''
      mkdir $out
      ln -s ${pluginConf} $out/nixos-config
    '';
  };

  # Copy one Munin plugin into the Nix store with a specific name.
  # This is suitable for use with plugins going directly into /etc/munin/plugins,
  # i.e. munin.extraPlugins.
  internOnePlugin = name: path:
    "cp -a '${path}' '${name}'";

  # Copy an entire tree of Munin plugins into a single directory in the Nix
  # store, with no renaming.
  # This is suitable for use with munin-node-configure --suggest, i.e.
  # munin.extraAutoPlugins.
  internManyPlugins = name: path:
    "find '${path}' -type f -perm /a+x -exec cp -a -t . '{}' '+'";

  # Use the appropriate intern-fn to copy the plugins into the store and patch
  # them afterwards in an attempt to get them to run on NixOS.
  internAndFixPlugins = name: intern-fn: paths:
    pkgs.runCommand name {} ''
      mkdir -p "$out"
      cd "$out"
      ${lib.concatStringsSep "\n"
          (lib.attrsets.mapAttrsToList intern-fn paths)}
      chmod -R u+w .
      find . -type f -exec sed -E -i '
        s,(/usr)?/s?bin/,/run/current-system/sw/bin/,g
      ' '{}' '+'
    '';

  # TODO: write a derivation for munin-contrib, so that for contrib plugins
  # you can just refer to them by name rather than needing to include a copy
  # of munin-contrib in your nixos configuration.
  extraPluginDir = internAndFixPlugins "munin-extra-plugins.d"
    internOnePlugin nodeCfg.extraPlugins;

  extraAutoPluginDir = internAndFixPlugins "munin-extra-auto-plugins.d"
    internManyPlugins
    (builtins.listToAttrs
      (map
        (path: { name = baseNameOf path; value = path; })
        nodeCfg.extraAutoPlugins));

  systemPath = map (v: "${v}/bin") (with pkgs; [
    munin smartmontools "/run/current-system/sw" "/run/wrappers"
  ]);

in

{
  options = {
    services.munin-node = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Enable Munin Node agent. Munin node listens on 0.0.0.0 and
          by default accepts connections only from 127.0.0.1 for security reasons.
          See <link xlink:href='http://guide.munin-monitoring.org/en/latest/architecture/index.html' />.
        '';
      };

      extraConfig = mkOption {
        default = "";
        type = types.lines;
        description = ''
          <filename>munin-node.conf</filename> extra configuration. See
          <link xlink:href='http://guide.munin-monitoring.org/en/latest/reference/munin-node.conf.html' />
        '';
      };

      extraPluginConfig = mkOption {
        default = "";
        type = types.lines;
        description = ''
          <filename>plugin-conf.d</filename> extra plugin configuration. See
          <link xlink:href='http://guide.munin-monitoring.org/en/latest/plugin/use.html' />
        '';
        example = ''
          [fail2ban_*]
          user root
        '';
      };

      extraPlugins = mkOption {
        default = {};
        type = with types; attrsOf path;
        description = ''
          Additional Munin plugins to activate. Keys are the name of the plugin
          symlink, values are the path to the underlying plugin script. You
          can use the same plugin script multiple times (e.g. for wildcard
          plugins).
          Note that these plugins do not participate in autoconfiguration. If
          you want to autoconfigure additional plugins, use
          <option>services.munin-node.extraAutoPlugins</option>.
          Plugins enabled in this manner take precedence over autoconfigured
          plugins.
          Plugins will be copied into the Nix store, and it will attempt to
          modify them to run properly by fixing hardcoded references to
          <literal>/bin</literal>, <literal>/usr/bin</literal>,
          <literal>/sbin</literal>, and <literal>/usr/sbin</literal>.
        '';
        example = literalExample ''
          {
            zfs_usage_bigpool = /src/munin-contrib/plugins/zfs/zfs_usage_;
            zfs_usage_smallpool = /src/munin-contrib/plugins/zfs/zfs_usage_;
            zfs_list = /src/munin-contrib/plugins/zfs/zfs_list;
          };
        '';
      };

      extraAutoPlugins = mkOption {
        default = [];
        type = with types; listOf path;
        description = ''
          Additional Munin plugins to autoconfigure, using
          <literal>munin-node-configure --suggest</literal>. These should be
          the actual paths to the plugin files (or directories containing them),
          not just their names.
          If you want to manually enable individual plugins instead, use
          <option>services.munin-node.extraPlugins</option>.
          Note that only plugins that have the 'autoconfig' capability will do
          anything if listed here, since plugins that cannot autoconfigure
          won't be automatically enabled by
          <literal>munin-node-configure</literal>.
          Plugins will be copied into the Nix store, and it will attempt to
          modify them to run properly by fixing hardcoded references to
          <literal>/bin</literal>, <literal>/usr/bin</literal>,
          <literal>/sbin</literal>, and <literal>/usr/sbin</literal>.
        '';
        example = literalExample ''
          [
            /src/munin-contrib/plugins/zfs
            /src/munin-contrib/plugins/ssh
          ];
        '';
      };

      disabledPlugins = mkOption {
        # TODO: figure out why Munin isn't writing the log file and fix it.
        # In the meantime this at least suppresses a useless graph full of
        # NaNs in the output.
        default = [ "munin_stats" ];
        type = with types; listOf str;
        description = ''
          Munin plugins to disable, even if
          <literal>munin-node-configure --suggest</literal> tries to enable
          them. To disable a wildcard plugin, use an actual wildcard, as in
          the example.
          munin_stats is disabled by default as it tries to read
          <literal>/var/log/munin/munin-update.log</literal> for timing
          information, and the NixOS build of Munin does not write this file.
        '';
        example = [ "diskstats" "zfs_usage_*" ];
      };
    };
  };

  config = (mkIf nodeCfg.enable {
    nixpkgs.config.packageOverrides = super: {
      # https://github.com/NixOS/nixpkgs/issues/70930
      # perl 5.30 breaks plugins
      munin = super.munin.override {
        perlPackages = super.perl528Packages;
        rrdtool = super.rrdtool.override {
          perl = super.perl528Packages.perl;
        };
      };
    };

    environment.systemPackages = [ pkgs.munin ];

    users.users = {
      munin = {
        description = "Munin monitoring user";
        group = "munin";
        uid = config.ids.uids.munin;
        home = "/var/lib/munin";
      };
    };

    users.groups = {
      munin = { gid = config.ids.gids.munin; };
    };

    runit.services.munin-node = {
      run = ''
        export PATH="${concatStringsSep ":" systemPath}:$PATH"
        export MUNIN_LIBDIR="${pkgs.munin}/lib"
        export MUNIN_PLUGSTATE="/run/munin"
        export MUNIN_LOGDIR="/var/log/munin"

        # munin_stats plugin breaks as of 2.0.33 when this doesn't exist
        mkdir -p /run/munin
        chown munin:munin /run/munin

        echo "Updating munin plugins..."
        mkdir -p /etc/munin/plugins
        rm -rf /etc/munin/plugins/*

        # Autoconfigure builtin plugins
        ${pkgs.munin}/bin/munin-node-configure --suggest --shell --families contrib,auto,manual --config ${nodeConf} --libdir=${pkgs.munin}/lib/plugins --servicedir=/etc/munin/plugins --sconfdir=${pluginConfDir} 2>/dev/null | ${pkgs.bash}/bin/bash

        # Autoconfigure extra plugins
        ${pkgs.munin}/bin/munin-node-configure --suggest --shell --families contrib,auto,manual --config ${nodeConf} --libdir=${extraAutoPluginDir} --servicedir=/etc/munin/plugins --sconfdir=${pluginConfDir} 2>/dev/null | ${pkgs.bash}/bin/bash

        ${lib.optionalString (nodeCfg.extraPlugins != {}) ''
          # Link in manually enabled plugins
          ln -f -s -t /etc/munin/plugins ${extraPluginDir}/*
        ''}

        ${lib.optionalString (nodeCfg.disabledPlugins != []) ''
          # Disable plugins
          cd /etc/munin/plugins
          rm -f ${toString nodeCfg.disabledPlugins}
        ''}

        exec ${pkgs.munin}/sbin/munin-node --config ${nodeConf} --servicedir /etc/munin/plugins/ --sconfdir=${pluginConfDir}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  });
}
