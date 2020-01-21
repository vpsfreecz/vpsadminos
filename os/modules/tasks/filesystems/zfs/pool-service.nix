{ config, pkgs, lib, ... }:
{ name, pool, zpoolCreateScript, importLib, packages }:
with lib;
let
  # Get a submodule without any embedded metadata
  _filter = x: filterAttrsRecursive (k: v: k != "_module") x;

  osctl = "${pkgs.osctl}/bin/osctl";
  zpool = "${packages.zfsUser}/bin/zpool";
  zfs = "${packages.zfsUser}/bin/zfs";

  mount = pkgs.substituteAll {
    name = "mount.rb";
    src = ./mount.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
    zfs = packages.zfsUser;
  };

  properties = mapAttrsToList (k: v: "\"${k}=${v}\"") pool.properties;

  datasets = pkgs.writeText "pool-${name}-datasets.json"
                            (builtins.toJSON (_filter pool.datasets));

  guidOrEmpty = optionalString (!isNull pool.guid) pool.guid;
in {
  run = ''
    ${importLib}

    # Loop across the import until it succeeds, because the devices needed may
    # not be discovered yet.
    if poolImported "${name}"; then
      echo "Pool ${name} already imported"
    else
      importName="${if isNull pool.guid then name else pool.guid}"
      for trial in `seq 1 60`; do
        echo "Checking status of pool ${name}"

        if poolReady "${name}" "${guidOrEmpty}" > /dev/null ; then
          echo "Attempting to import pool ${name} ${optionalString (!isNull pool.guid) "(ID=${pool.guid})"}"
          msg="$(poolImport "$importName" 2>&1)"
          isImported=$?

          if [ $isImported == 0 ] ; then
            echo "Pool ${name} imported"
            break
          else
            echo "Unable to import pool ${name}: $msg"
          fi
        else
          echo "Waiting for devices..."
        fi

        sleep 1
      done

      if ! poolImported "${name}" ; then
        echo "All attempts to cleanly import pool ${name} have failed"
        echo "Importing a possibly degraded pool in 10s"
        sleep 10
        poolImport "$importName"
      fi

      if ! poolImported "${name}" ; then
        ${if pool.doCreate then ''
          ${zpoolCreateScript name pool}/bin/do-create-pool-${name} --force \
          || fail "Unable to create pool ${name}"
        '' else ''
          echo "Unable to import pool ${name}"
          sv once pool-${name}
          exit 1
        ''}
      fi
    fi

    stat="$( ${zpool} status ${name} )"
    test $? && echo "$stat" | grep DEGRADED &> /dev/null && \
      echo -e "Pool ${name} is DEGRADED!"

    ${optionalString ((length properties) > 0) ''
    echo "Configuring pool ${name}"
    ${concatMapStringsSep "\n" (v: "${zpool} set ${v} ${name}") properties}
    ''}

    echo "Mounting datasets..."
    ${mount} ${name} ${datasets}

    active=$(${zfs} get -Hp -o value org.vpsadminos.osctl:active ${name})

    echo "Waiting for osctld..."
    waitForOsctld

    if [ "$active" == "yes" ] ; then
      if  ! osctlEntityExists pool ${name} ; then
        echo "Importing pool ${name} into osctld"
        ${osctl} pool import ${name} \
          || fail "Unable to import pool ${name} into osctld"
      fi

    elif ${if pool.install then "true" else "false"} ; then
      echo "Installing pool ${name} into osctld"
      ${osctl} pool install ${name} \
        || fail "Unable to install pool ${name} into osctld"
    fi

    ${optionalString (hasAttr name config.osctl.pools) ''
    echo "Configuring osctl pool ${name}"
    ${osctl} pool set parallel-start ${name} ${toString config.osctl.pools.${name}.parallelStart}
    ${osctl} pool set parallel-stop ${name} ${toString config.osctl.pools.${name}.parallelStop}
    ''}

    ${optionalString config.services.nfs.server.enable ''
    echo "Sharing datasets..."
    waitForService nfsd
    ${zfs} share -r ${name}
    ''}
  '';
  oneShot = true;
  log.enable = true;
  log.sendTo = "127.0.0.1";
}
