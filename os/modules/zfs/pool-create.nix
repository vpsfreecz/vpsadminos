{ config, pkgs, lib, ... }:
{ name, pool }:
with lib;
let
   doWipe = concatMapStringsSep "\n" (d: ''
    dd if=/dev/zero of=/dev/${d} count=1024
    sectors="$( sfdisk -l /dev/${d} | egrep -o "([[:digit:]]+) sectors" | cut -d' ' -f1 )"
    dd if=/dev/zero of=/dev/${d} seek="$(( $sectors - 1024 ))" count=1024
  '');

  doPartition =
    let
      toSectorSize = x: if x == null then "" else "size=${toString (x * 2048 * 1024)},";
      mkParts = x: concatStrings (intersperse "\n" (mapAttrsToList (n: v: "${replaceStrings ["p"] [""] n}:${toSectorSize v.sizeGB}type=${v.type}") x));
    in
      x: concatStrings (mapAttrsToList (k: v: "echo '${mkParts v};' | sfdisk /dev/${k}\n") x);

  properties = concatStringsSep " " (mapAttrsToList (k: v: "-o \"${k}=${v}\"") pool.properties);

in pkgs.writeScriptBin "do-create-pool-${name}" ''
  #!/bin/sh
  if [ "$1" != "-f" ] && [ "$1" != "--force" ] ; then
    echo "WARNING: this program creates zpool ${name} and may destroy existing"
    echo "data on configured disks in the process. Use at own risk!"
    echo

    ${optionalString (pool.wipe != []) ''
      echo "Disks to wipe:"
      echo "  ${concatStringsSep " " pool.wipe}"
      echo
    ''}

    ${optionalString (pool.partition != {}) ''
      echo "Disks to partition:"
      echo "  ${concatStringsSep " " (mapAttrsToList (disk: _: disk) pool.partition)}"
      echo
    ''}

    echo "zpool to create:"
    echo "  zpool create ${properties} ${name} ${pool.layout}"
    ${optionalString (pool.logs != "") ''
      echo "  zpool add ${name} log ${pool.logs}"
    ''}
    ${optionalString (pool.caches != "") ''
      echo "  zpool add ${name} cache ${pool.caches}"
    ''}
    echo

    read -p "Write uppercase 'yes' to continue: " input
    if [ "$input" != "YES" ] ; then
      echo "Aborting"
      exit 1
    fi
  fi

  ${optionalString (pool.wipe != []) ''
    echo "Wiping disks"
    ${doWipe pool.wipe}
  ''}

  ${optionalString (pool.partition != {}) ''
    echo "Partitioning disks"
    ${doPartition pool.partition}
  ''}

  echo "Creating pool \"${name}\""
  zpool create ${properties} ${name} ${pool.layout} || exit 1

  ${optionalString (pool.logs != "") ''
    echo "Adding logs"
    zpool add ${name} log ${pool.logs} || exit 1
  ''}

  ${optionalString (pool.caches != "") ''
    echo "Adding caches"
    zpool add ${name} cache ${pool.caches} || exit 1
  ''}
''
