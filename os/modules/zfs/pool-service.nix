{ config, pkgs, lib, ... }:
{ name, pool, zpoolCreateScript, importLib }:
with lib;
let
  # Get a submodule without any embedded metadata
  _filter = x: filterAttrsRecursive (k: v: k != "_module") x;

  osctl = "${pkgs.osctl}/bin/osctl";

  mount = pkgs.substituteAll {
    name = "mount.rb";
    src = ./mount.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
  };

  properties = mapAttrsToList (k: v: "\"${k}=${v}\"") pool.properties;

  datasets = pkgs.writeText "pool-${name}-datasets.json"
                            (builtins.toJSON (_filter pool.datasets));
in {
  run = ''
    ${importLib}

    echo "Importing ZFS pool \"${name}\""
    # Loop across the import until it succeeds, because the devices needed may
    # not be discovered yet.
    if ! poolImported "${name}"; then
      for trial in `seq 1 60`; do
        poolReady "${name}" > /dev/null && msg="$(poolImport "${name}" 2>&1)" && break
        sleep 1
        echo "Waiting for devices..."
      done

      if [[ -n "$msg" ]]; then
        echo "$msg";
      fi

      # Try one last time, e.g. to import a degraded pool.
      poolImported "${name}" || poolImport "${name}"

      if ! poolImported "${name}" ; then
        ${if pool.doCreate then ''
          ${zpoolCreateScript name pool}/bin/do-create-pool-${name} --force \
          || fail "unable to create zpool ${name}"
        '' else ''fail "unable to import zpool ${name}"''}
      fi
    fi

    stat="$( zpool status ${name} )"
    test $? && echo "$stat" | grep DEGRADED &> /dev/null && \
      echo -e "\n\n[1;31m>>> Pool is DEGRADED!! <<<[0m"

    ${optionalString ((length properties) > 0) ''
    echo "Configuring zpool"
    ${concatMapStringsSep "\n" (v: "zpool set ${v} ${name}") properties}
    ''}

    echo "Mounting datasets..."
    ${mount} ${name} ${datasets}

    active=$(zfs get -Hp -o value org.vpsadminos.osctl:active ${name})

    waitForOsctld

    if [ "$active" == "yes" ] ; then
      osctlEntityExists pool ${name} \
        || ${osctl} pool import ${name} \
        || fail "unable to import osctl pool ${name}"

    elif ${if pool.install then "true" else "false"} ; then
      ${osctl} pool install ${name} \
      || fail "unable to install zpool ${name} into osctld"
    fi

    ${optionalString (hasAttr name config.osctl.pools) ''
    echo "Configuring osctl pool"
    ${osctl} pool set parallel-start ${name} ${toString config.osctl.pools.${name}.parallelStart}
    ${osctl} pool set parallel-stop ${name} ${toString config.osctl.pools.${name}.parallelStop}
    ''}

    ${optionalString config.services.nfs.server.enable ''
    echo "Sharing datasets..."
    waitForService nfsd
    zfs share -r ${name}
    ''}

    # TODO: this could be option runit.services.<service>.autoRestart = always/on-failure;
    sv once pool-${name}
  '';

  log.enable = true;
  log.sendTo = "127.0.0.1";
}
