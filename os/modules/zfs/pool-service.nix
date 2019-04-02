{ config, pkgs, lib, ... }:
{ name, pool, zpoolCreateScript }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";
in {
  run = ''
    zpool list ${name} > /dev/null

    if [ "$?" != "0" ] ; then
      echo "Importing ZFS pool \"${name}\""
      zpool import -N ${name}

      if [ "$?" != "0" ] ; then
        ${if pool.doCreate then ''
          ${zpoolCreateScript name pool}/bin/do-create-pool-${name} --force \
          || fail "unable to create zpool ${name}"
        '' else ''fail "unable to import zpool ${name}"''}
      fi
    fi

    stat="$( zpool status ${name} )"
    test $? && echo "$stat" | grep DEGRADED &> /dev/null && \
      echo -e "\n\n[1;31m>>> Pool is DEGRADED!! <<<[0m"

    echo "Mounting datasets..."
    datasets="$(zfs list -Hr -t filesystem -o name,canmount,mounted ${name} \
      | grep $'\ton' `# canmount=on` \
      | grep $'\tno' `# mounted=no` \
      | awk '{ print $1; }')"
    count=$(echo "$datasets" | wc -l)
    i=1

    for ds in $datasets ; do
      echo "[''${i}/''${count}] Mounting $ds"
      zfs mount $ds
      i=$(($i+1))
    done

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

    datasets="$(zfs list -Hr -t filesystem -o name,mounted,sharenfs ${name} \
      | grep $'\tyes' `# mounted=yes` \
      | grep -v $'\toff' `# sharenfs!=off` \
      | awk '{ print $1; }')"
    count=$(echo "$datasets" | wc -l)
    i=1

    for ds in $datasets ; do
      echo "[''${i}/''${count}] Sharing $ds"
      zfs share $ds
      i=$(($i+1))
    done
    ''}

    # TODO: this could be option runit.services.<service>.autoRestart = always/on-failure;
    sv once pool-${name}
  '';

  log.enable = true;
  log.sendTo = "127.0.0.1";
}
