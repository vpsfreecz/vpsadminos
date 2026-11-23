args:
import ../../../../suite/zfs/full-suite.nix (
  args
  // {
    testArgs.exactReleaseTest = {
      name = "zfs-rsend-promoted-cycle-6.18.49";
      kernelVersion = "6.18.49";
      description = "Verify bounded refusal of a promoted-clone replication cycle";
      body = "rsend/rsend_008_pos";
      postInstall = ''
        substituteInPlace "$out/share/zfs/zfs-tests/tests/functional/rsend/rsend_008_pos.ksh" \
          --replace-fail 'log_unsupported "Occasionally hangs"' \
            'log_note "Exercising historical promoted-send case (issue 6066)"' \
          --replace-fail 'log_must eval "zfs send -R $POOL@final > $BACKDIR/pool-final-R"' \
            $'log_mustnot eval "zfs send -R $POOL@final > $BACKDIR/pool-final-R 2> $BACKDIR/pool-final-R.err"\nlog_must grep -Fq "cyclic parent and clone origin dependencies" "$BACKDIR/pool-final-R.err"\nlog_pass "Promoted-clone send cycle refused by the pinned fork"'
        substituteInPlace "$out/usr/share/initramfs-tools/scripts/zfs-tests.sh" \
          --replace-fail 'timeout = 3600' 'timeout = 300'
      '';
    };
  }
)
