import ../../make-test.nix (
  { pkgs }:
  let
    reproducer = pkgs.writeScript "reproducer.sh" ''
      #!/bin/sh
      zfs create -p -o mountpoint=/zfs-deadlock tank/deadlock

      echo 1048576  > /sys/module/zfs/parameters/zfs_dirty_data_max
      echo 120      > /sys/module/zfs/parameters/zfs_txg_timeout
      echo 0        > /sys/module/zfs/parameters/zfs_delay_min_dirty_percent

      mkdir -p /zfs-deadlock/{upper,work,lower} /mnt/zdeadlock

      for i in {1..1000} ; do
        echo $i
        mount -t overlay zdeadlock -o lowerdir=/zfs-deadlock/lower,upperdir=/zfs-deadlock/upper,workdir=/zfs-deadlock/work /mnt/zdeadlock
        umount /mnt/zdeadlock
      done
    '';
  in
  {
    name = "zfs-overlayfs-deadlock";

    description = ''
      Test that overlayfs mounts do not result in ZFS deadlock

      This bug was introduced by commit "Linux: O_TMPFILE and insert inode hash rework",
      example broken ZFS commit is 2429ad6a83e2b056e1a38c5ce7b1d3dda6de7919. Fixed
      commit is fe92f03d204035d0543bda46fd54ca75a007dce6.

      Diff between the two commits:

      ```
      git diff 2429ad6a83e2b056e1a38c5ce7b1d3dda6de7919 fe92f03d204035d0543bda46fd54ca75a007dce6
      diff --git a/module/os/linux/zfs/zfs_vnops_os.c b/module/os/linux/zfs/zfs_vnops_os.c
      index 7d544dc62..b60cd168a 100644
      --- a/module/os/linux/zfs/zfs_vnops_os.c
      +++ b/module/os/linux/zfs/zfs_vnops_os.c
      @@ -3185,7 +3185,6 @@ top:
                              goto commit_unlink_td_szp;
                      }
                      VERIFY0(insert_inode_locked(ZTOI(wzp)));
      -               mark_inode_dirty(ZTOI(wzp));
                      unlock_new_inode(ZTOI(wzp));
                      break;
              }
      ```

      Example available-kernels.nix fragment for reproduction:

      ```
      "6.12.34" = {
        rev = "ac64d280f3e416449a318a811987ae531c8f7e97";
        sha256 = "sha256-fBwFGKuhxKnXf04Ck98cwoJ6HwC4LpDLGXcwd1JmYIY=";
        zfs = {
          rev = "00d8dc06bad765d7a1357c4f418fc5bb8a5feca8";
          sha256 = "sha256-AOgJm8fPDa0kDhyL4PFBuz+uz1Rz7zsH9C9AXn5GnMA=";
        };
      };
      ```

      However, this kernel was fixed by a live patch, so disable it to reproduce:

      ```
      services.live-patches.enable = false;
      ```

      When the deadlock is hit, the mount command will eventually hang in D
      and ZFS txg will be left in quiescing (Q) state.
    '';

    tags = [
      "ci"
      "regression"
    ];

    machine = import ../../machines/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool('tank')

      machine.mkdir('/scripts')
      machine.push_file("${reproducer}", "/scripts/reproducer.sh")

      begin
        status, _ = machine.execute('/scripts/reproducer.sh', timeout: 300)
      rescue OsVm::TimeoutError
        machine.kill
        raise 'ZFS deadlock in overlayfs mount detected'
      else
        expect(status).to eq(0)
      end
    '';
  }
)
