{ config, lib, pkgs, utils, shared, ... }:
with lib;
let
  serviceRun =
    { pool, name, cfg, osctl, osctlPool, hooks, hookCaller, conf, yml, boolToStr }:
      let
        argList =
          (map (v: "--${v} ${cfg.${v}}")
               (filter (v: cfg.${v} != null) [ "distribution" "version" "arch" "vendor" "variant" ]))
          ++
          (optional (cfg.template.type == "remote" && cfg.template.repository != null)
                    ''--repository "${cfg.template.repository}"'')
          ++
          (optional (cfg.template.type == "archive") ''--from-archive "${cfg.template.path}"'')
          ++
          (optional (cfg.template.type == "stream") ''--from-stream "${cfg.template.path}"'');

        createArgs = concatStringsSep " " argList;

      in ''
        ${osctl} pool show ${pool} &> /dev/null
        hasPool=$?
        if [ "$hasPool" != "0" ] ; then
          echo "Waiting for pool ${pool}"
          exit 1
        fi
        
        ${osctlPool} user show ${cfg.user} &> /dev/null
        hasUser=$?
        if [ "$hasUser" != "0" ] ; then
          echo "Waiting for user ${pool}:${cfg.user}"
          exit 1
        fi
        
        ${osctlPool} group show ${cfg.group} &> /dev/null
        hasGroup=$?
        if [ "$hasGroup" != "0" ] ; then
          echo "Waiting for group ${pool}:${cfg.group}"
          exit 1
        fi

        ${optionalString (cfg.template.type == "remote" && cfg.template.repository != null) ''
        ${osctlPool} repository show ${cfg.template.repository} &> /dev/null
        hasRepo=$?
        if [ "$hasRepo" != "0" ] ; then
          echo "Waiting for repository ${pool}:${cfg.template.repository}"
          exit 1
        fi
        ''}
        
        ${osctlPool} ct show ${name} &> /dev/null
        hasCT=$?
        if [ "$hasCT" == "0" ] ; then
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

          if [ "${cfg.user}" != "$currentUser" ] \
             || [ "${cfg.group}" != "$currentGroup" ] \
             || [ "${yml}" != "$currentConfig" ] ; then
            echo "Reconfiguring the container"

            if [ "$currentState" != "stopped" ] ; then
              ${osctlPool} ct stop ${name}
              originalState="$currentState"
              currentState="stopped"
            fi

            if [ "${cfg.user}" != "$currentUser" ] ; then
              echo "Changing user from $currentUser to ${cfg.user}"
              ${osctlPool} ct chown ${name} ${cfg.user} || exit 1
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

          ${osctlPool} ct new \
                              --user ${cfg.user} \
                              --group ${cfg.group} \
                              ${createArgs} \
                              ${name} || exit 1

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
          ${osctlPool} ct start ${name}
        fi

        if [ "$createdContainer" == "y" ] ; then
          ${optionalString (cfg.hooks.post-create != null) ''
            echo "Executing post-create script hook"
            ${hookCaller "post-create" cfg.hooks.post-create}
          ''}
          : # do nothing
        fi

        sv once ct-${pool}-${name}
      '';
in
{
  serviceRun = serviceRun;
}
