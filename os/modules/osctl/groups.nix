{ config, lib, pkgs, utils, shared, ... }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  sortGroups = groups:
    sort (a: b: a.group < b.group)
         (mapAttrsToList (group: cfg: { inherit group cfg; }) groups);

  createGroups = pool: groups: concatStringsSep "\n\n" (map ({group, cfg}: (
    let
      osctlPool = "${osctl} --pool ${pool}";

      cgparams = {
        parameters = map (cgparam: {
          subsystem = cgparam.subsystem;
          parameter = cgparam.name;
          value = cgparam.value;
        }) (shared.buildCGroupParams cfg.cgparams);
      };

      safeName = replaceStrings [ "/" ] [ "." ] group;

      cgparamsJson = pkgs.writeText "group-${safeName}-cgparams.json" (builtins.toJSON cgparams);

      devices = {
        devices = map (dev: {
          inherit (dev) type major minor mode;
          dev_name = if dev.name == "" then null else dev.name;
          "inherit" = dev.provide;
        }) cfg.devices;
      };

      devicesJson = pkgs.writeText "group-${safeName}-devices.json" (builtins.toJSON devices);

    in ''
      ### Group ${pool}:${group}
      ${osctlPool} group show ${group} &> /dev/null
      hasGroup=$?
      if [ "$hasGroup" == "0" ] ; then
        echo "Group ${pool}:${group} already exists"

        ${osctlPool} group set attr ${group} org.vpsadminos.osctl:declarative yes

        lines=( $(${osctlPool} group show -H -o org.vpsadminos.osctl:cgparams,org.vpsadminos.osctl:devices ${group}) )
        currentCgparams="''${lines[0]}"
        currentDevices="''${lines[1]}"

        if [ "${cgparamsJson}" != "$currentCgparams" ] ; then
          echo "Reconfiguring cgroup parameters"
          cat ${cgparamsJson} | ${osctlPool} group cgparams replace ${group} \
            && ${osctlPool} group set attr ${group} org.vpsadminos.osctl:cgparams ${cgparamsJson}
        fi

        if [ "${devicesJson}" != "$currentDevices" ] ; then
          echo "Reconfiguring devices"
          cat ${devicesJson} | ${osctlPool} group devices replace ${group} \
            && ${osctlPool} group set attr ${group} org.vpsadminos.osctl:devices ${devicesJson}
        fi

      else
        echo "Creating group ${pool}:${group}"
        ${osctlPool} group new ${group}
        ${osctlPool} group set attr ${group} org.vpsadminos.osctl:declarative yes

        echo "Configuring cgroup parameters"
        cat ${cgparamsJson} | ${osctlPool} group cgparams replace ${group} \
          && ${osctlPool} group set attr ${group} org.vpsadminos.osctl:cgparams ${cgparamsJson}

        echo "Configuring devices"
        cat ${devicesJson} | ${osctlPool} group devices replace ${group} \
          && ${osctlPool} group set attr ${group} org.vpsadminos.osctl:devices ${devicesJson}
      fi
    '')) (sortGroups groups));
in
{
  type = {
    options = {
      cgparams = shared.mkCGParamsOption;
      devices = shared.mkDevicesOption;
    };
  };

  mkServices = pool: groups: mkIf (groups != {}) {
    "groups-${pool}" = {
      run = ''
        ${osctl} pool show ${pool} &> /dev/null
        hasPool=$?
        if [ "$hasPool" != "0" ] ; then
          echo "Waiting for pool ${pool}"
          exit 1
        fi

        ${createGroups pool groups}

        sv once groups-${pool}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
