{ config, lib, pkgs, utils, shared, ... }:
with lib;
let
  serviceRun =
    { pool, name, cfg, osctl, osctlPool, hooks, hookCaller, conf, yml, boolToStr
    , hasUser, user }:
      let
        ctNewArgList =
          (map (v: "--${v} ${cfg.${v}}")
               (filter (v: cfg.${v} != null) [ "distribution" "version" "arch" "vendor" "variant" ]))
          ++
          (optional (cfg.image.repository != null)
                    ''--repository "${cfg.image.repository}"'');

        createCtNewArgs = concatStringsSep " " ctNewArgList;

        createMethods = {
          ct-new = ''
            ${osctlPool} ct new \
                                ${optionalString hasUser "--user ${user}"} \
                                --group ${cfg.group} \
                                ${createCtNewArgs} \
                                ${name} || exit 1
          '';
          ct-import = ''
            ${osctlPool} ct import \
                                --as-id ${name} \
                                ${optionalString hasUser "--as-user ${user}"} \
                                --as-group ${cfg.group} \
                                ${cfg.image.path} || exit 1
          '';
        };

        createMethod =
          if cfg.image.path == null then
            createMethods.ct-new
          else
            createMethods.ct-import;

      in ''
        waitForOsctld
        waitForOsctlEntityAttr pool "${pool}" state active
        ${optionalString hasUser ''waitForOsctlEntity user "${user}"''}
        waitForOsctlEntity group "${cfg.group}"

        ${optionalString (cfg.image.repository != null) ''
        waitForOsctlEntity repository "${cfg.image.repository}"
        ''}

        if osctlEntityExists ct "${name}" ; then
          echo "Container ${pool}:${name} already exists"
          lines=( $(${osctlPool} ct show -H -o rootfs,state,user,group,org.vpsadminos.osctl:config ${name}) )
          if [ "$?" != 0 ] ; then
            echo "Unable to get the container's status"
            exit 1
          fi

          rootfs="''${lines[0]}"
          currentState="''${lines[1]}"
          currentUser="''${lines[2]}"
          currentGroup="''${lines[3]}"
          currentConfig="''${lines[4]}"

          if [ "${user}" != "$currentUser" ] \
             || [ "${cfg.group}" != "$currentGroup" ] \
             || [ "${yml}" != "$currentConfig" ] ; then
            echo "Reconfiguring the container"

            if [ "$currentState" != "stopped" ] ; then
              ${osctlPool} ct stop ${name}
              originalState="$currentState"
              currentState="stopped"
            fi

            if [ "${user}" != "$currentUser" ] ; then
              echo "Changing user from $currentUser to ${user}"
              ${osctlPool} ct chown ${name} ${user} || exit 1
            fi

            if [ "${cfg.group}" != "$currentGroup" ] ; then
              echo "Changing group from $currentGroup to ${cfg.group}"
              ${osctlPool} ct chgrp ${name} ${cfg.group} || exit 1
            fi

            if [ "${yml}" != "$currentConfig" ] ; then
              echo "Replacing config"
              cat ${yml} | ${osctlPool} ct config replace ${name} || exit 1
              ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:config ${yml}
              ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:declarative yes
            fi
          fi

        else
          echo "Creating container '${name}'"

          ${optionalString (cfg.hooks.pre-create != null) ''
            echo "Executing pre-create script hook"
            ${hookCaller "pre-create" cfg.hooks.pre-create}
            preStartStatus=$?
            case $preStartStatus in
              0) ;;
              2)
                echo "pre-create hook exited with 2, aborting"
                sv once ct-${pool}-${name}
                exit 1
                ;;
              *)
                echo "pre-create hook exited with $preStartStatus, restarting"
                exit 1
                ;;
            esac
          ''}

          ${createMethod}
          cat ${yml} | ${osctlPool} ct config replace ${name} || exit 1
          ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:declarative yes
          ${osctlPool} ct set attr ${name} org.vpsadminos.osctl:config ${yml}

          createdContainer=y
        fi

        echo "Installing user script hooks"
        lines=( $(zfs get -Hp -o value mountpoint,org.vpsadminos.osctl:dataset ${pool}) )
        mountpoint="''${lines[0]}"
        osctlDataset="''${lines[1]}"

        [ "$osctlDataset" != "-" ] \
          && mountpoint="$(zfs get -Hp -o value mountpoint $osctlDataset)"

        hookDir="$mountpoint/hook/ct/${name}"

        rm -f "$hookDir/*"
        ${hooks}

        if [ "$createdContainer" == "y" ] ; then
          ${optionalString (cfg.hooks.on-create != null) ''
            echo "Executing on-create script hook"
            ${hookCaller "on-create" cfg.hooks.on-create}
          ''}
          : # do nothing
        fi

        if [ "$originalState" == "running" ] \
           || ${boolToStr (cfg.autostart != null)} ; then
          echo "Starting container ${pool}:${name}"
          ${osctlPool} ct start --queue \
                                ${optionalString (cfg.autostart != null) "--priority ${toString cfg.autostart.priority}"} \
                                ${name}
        fi

        if [ "$createdContainer" == "y" ] ; then
          ${optionalString (cfg.hooks.post-create != null) ''
            echo "Executing post-create script hook"
            ${hookCaller "post-create" cfg.hooks.post-create}
          ''}
          : # do nothing
        fi
      '';
in
{
  serviceRun = serviceRun;
}
