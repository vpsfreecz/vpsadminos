{ config, lib, pkgs, utils, ... }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  allocation = {
    options = {
      index = mkOption {
        type = types.ints.unsigned;
        description = ''
          Index of the starting block
        '';
      };

      count = mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = ''
          Number of blocks to allocate
        '';
      };

      owner = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional allocation owner
        '';
      };
    };
  };

  createIdRanges = pool: ranges: concatStringsSep "\n\n" (mapAttrsToList (range: cfg: (
    let
      osctlPool = "${osctl} --pool ${pool}";

      ensureBlocks = ''
        allocationList="$(mktemp -t block-allocations.XXXXXX)"
        ${concatMapStringsSep "\n\n" ensureBlock cfg.table}
        source $allocationList
        rm -f $allocationList
      '';

      allocateBlock = { index, count, owner, ... }: ''
        echo "Allocating block ${range}:${toString index}"
        ${osctlPool} id-range allocate \
          --block-index ${toString index} \
          --block-count ${toString count} \
          ${optionalString (owner != null) "--owner \"${owner}\""} \
          ${range} || fail "unable to allocate block at ${range}:${toString index}"
      '';

      freeBlock = { index, count, owner, ... }: ''
        echo "Freeing block ${range}:${toString index}"
        ${osctlPool} id-range free \
          --block-index ${toString index} \
          ${range} || fail "unable to free block at ${range}:${toString index}"
      '';

      formatOwner = owner: if owner == null then "-" else owner;

      ensureBlock = { index, count, owner, ... }@block: ''
        lines=( $(${osctlPool} id-range table show -H -o type,block_count,owner ${range} ${toString index} 2> /dev/null) )
        [ $? != 0 ] && fail "invalid allocation at ${range}:${toString index}"

        currentType="''${lines[0]}"
        currentBlockCount="''${lines[1]}"
        currentOwner="''${lines[2]}"

        if [ "$currentType" == "free" ] ; then
          cat <<EOF >> $allocationList
          ${allocateBlock block}
        EOF
        elif [ "$currentType" == "allocated" ] ; then
          if [ "$currentBlockCount" != "${toString count}" ] || \
             [ "$currentOwner" != "${formatOwner owner}" ] ; then
            ${freeBlock block}

            cat <<EOF >> $allocationList
            ${allocateBlock block}
        EOF
          fi
        fi
      '';
    in ''
      ### ID range ${pool}:${range}
      lines=( $(${osctlPool} id-range show -H -o start_id,block_size,block_count ${range} 2> /dev/null) )
      hasRange=$?
      if [ "$hasRange" == "0" ] ; then
        echo "ID range ${pool}:${range} already exists"

        currentStartId="''${lines[0]}"
        currentBlockSize="''${lines[1]}"
        currentBlockCount="''${lines[2]}"

        if [ "${toString cfg.startId}" != "$currentStartId" ] ; then
          echo "ID range ${pool}:${range} has an invalid startId: " \
               "expected ${toString cfg.startId}, found $currentStartId"
        fi

        if [ "${toString cfg.blockSize}" != "$currentBlockSize" ] ; then
          echo "ID range ${pool}:${range} has an invalid blockSize: " \
               "expected ${toString cfg.blockSize}, found $currentBlockSize"
        fi

        if [ "${toString cfg.blockCount}" != "$currentBlockCount" ] ; then
          echo "ID range ${pool}:${range} has an invalid blockCount: " \
               "expected ${toString cfg.blockCount}, found $currentBlockCount"
        fi

      else
        echo "Creating ID range ${pool}:${range}"
        ${osctlPool} id-range new \
          --start-id ${toString cfg.startId} \
          --block-size ${toString cfg.blockSize} \
          --block-count ${toString cfg.blockCount} \
          ${range} || fail "unable to create ID range"
        ${osctlPool} id-range set attr ${range} org.vpsadminos.osctl:declarative yes
      fi

      ${ensureBlocks}
    '')) ranges);
in
{
  type = {
    options = {
      startId = mkOption {
        type = types.ints.unsigned;
        description = ''
          The first user/group ID
        '';
      };

      blockSize = mkOption {
        type = types.ints.unsigned;
        default = 65536;
        description = ''
          Number of user/group IDs that make up the minimum allocation unit
        '';
      };

      blockCount = mkOption {
        type = types.ints.unsigned;
        description = ''
          How many blocks from
          <option>osctl.pools.&lt;pool&gt;.idRanges.&lt;range&gt;.startId</option>
          should the range include. Defines the maximum number of user namespace
          maps that can be allocated from this range.
        '';
      };

      table = mkOption {
        type = types.listOf (types.submodule allocation);
        description = ''
          Allocate blocks from the range.

          Allocated blocks removed from configuration will not be automatically
          freed.
        '';
      };
    };
  };

  mkServices = pool: ranges: mkIf (ranges != {}) {
    "id-ranges-${pool}" = {
      run = ''
        waitForOsctld
        waitForOsctlEntity pool ${pool}
        ${createIdRanges pool ranges}
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}

