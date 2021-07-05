{ config, lib, pkgs, utils, shared, ... }:
with lib;
let
  serviceRun =
    { pool, name, cfg, osctl, osctlPool, hooks, hookCaller, conf, yml, boolToStr
    , hasUser, user }:
      let
        toplevel = cfg.path;

        closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };

        postMount = pkgs.writeScript "ct-${pool}-${name}-post-mount" ''
          set -e

          rootfs="$OSCTL_CT_ROOTFS_MOUNT"

          echo "Configuring the root filesystem"
          mkdir -p "$rootfs"
          mkdir -p "$rootfs/dev" "$rootfs/etc" "$rootfs/proc" "$rootfs/run" \
                   "$rootfs/sbin" "$rootfs/sys"
          ln -sf "${toplevel}/init" "$rootfs/sbin/init"

          echo "Populating /nix/store"
          mkdir -p "$rootfs/nix/store" \
                   "$rootfs/nix/var/nix/gcroots" \
                   "$rootfs/nix/var/nix/profiles"

          ln -sf /run/current-system "$rootfs/nix/var/nix/gcroots/current-system"

          currentSystem=$(realpath "$rootfs/nix/var/nix/profiles/system")

          if [ "$?" != "0" ] || [ "$currentSystem" != "${toplevel}" ] ; then
            echo "System needs updating"
            cat ${closureInfo}/registration >> "$rootfs/nix-path-registration"
            ln -sf ${toplevel} "$rootfs/nix/var/nix/profiles/system"
            ln -sf ${toplevel}/init "$rootfs/sbin/init"
          else
            echo "System up-to-date"
          fi

          count=$(cat ${closureInfo}/store-paths | wc -l)
          i=1

          for storePath in $(cat ${closureInfo}/store-paths) ; do
            dst="$rootfs/''${storePath:1}"

            if [ -e "$dst" ] ; then
              echo "[$i/$count] Found $storePath"

            else
              echo "[$i/$count] Copying $storePath"
              cp -a $storePath $dst
            fi

            i=$(($i+1))
          done

          exit 0
        '';
      in ''
        waitForOsctld
        waitForOsctlEntityAttr pool "${pool}" state active
        ${optionalString hasUser ''waitForOsctlEntity user "${user}"''}
        waitForOsctlEntity group "${cfg.group}"

        mkdir -p /nix/var/nix/profiles/per-container
        mkdir -p /nix/var/nix/gcroots/per-container

        ln -sf ${toplevel} /nix/var/nix/profiles/per-container/${name}
        ln -sf ${toplevel} /nix/var/nix/gcroots/per-container/${name}

        if osctlEntityExists ct "${name}" ; then
          echo "Container ${pool}:${name} already exists"
          lines=( $(${osctlPool} ct show -H -o state,user,group,org.vpsadminos.osctl:config ${name}) )
          if [ "$?" != 0 ] ; then
            echo "Unable to get the container's status"
            exit 1
          fi

          currentState="''${lines[0]}"
          currentUser="''${lines[1]}"
          currentGroup="''${lines[2]}"
          currentConfig="''${lines[3]}"

          if [ "${user}" != "$currentUser" ] \
             || [ "${cfg.group}" != "$currentGroup" ] \
             || [ "${yml}" != "$currentConfig" ] ; then
            if [ "$currentState" != "stopped" ] ; then
              ${osctlPool} ct stop ${name}
              originalState="$currentState"
              currentState="stopped"
            fi

            echo "Reconfiguring the container"

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

          ${osctlPool} ct new \
                              ${optionalString hasUser "--user ${user}"} \
                              --group ${cfg.group} \
                              --distribution nixos \
                              --version ${conf.version} \
                              --arch ${conf.arch} \
                              --skip-image \
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
        mkdir -p "$hookDir/post-mount.d"
        ln -sf ${postMount} "$hookDir/post-mount.d/00-declarative-setup"
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
