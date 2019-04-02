{ config, pkgs, lib, ... }:
{ name, pool, zpoolCreateScript }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  mount = pkgs.substituteAll {
    name = "mount.rb";
    src = ./mount.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
  };

  share = pkgs.substituteAll {
    name = "share.rb";
    src = ./share.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
  };
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
    ${mount} ${name}

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
    ${share} ${name}
    ''}

    # TODO: this could be option runit.services.<service>.autoRestart = always/on-failure;
    sv once pool-${name}
  '';

  log.enable = true;
  log.sendTo = "127.0.0.1";
}
