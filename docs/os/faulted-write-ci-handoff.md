# Faulted-write correction: source and CI handoff

This integration selects Linux 6.12.109 and ZFS's faulted-write correction.
The 6.12.95 entry remains available with the same ZFS correction. The 6.12.48
kernel and ZFS pins are retained unchanged; that entry is not newly qualified
or claimed to contain this correction.

## Published sources

| Component | Revision |
| --- | --- |
| Linux 6.12.109 | `9ccd5d6597a6ddbe5b44fb885ddf96e4dbc332dd` |
| ZFS for 6.12 | `481845fca6ae3f61ca2262c1a5693a58ae364650` |
| ZFS regression on the 6.18 line | `460503da7b96a0f6a88d575565722ff5940b9eb1` |

The 6.12 change finishes writes with inaccessible source pages through the
normal accounting and range-lock release path. It preserves a successfully
copied prefix rather than retrying indefinitely while retaining a range lock.
The 6.18 line already carries equivalent product handling; its publication
adds the same regression without duplicating the implementation. Its OS pin
and runtime validation remain with the separate 6.18 integration workstream.

## Coverage handed to CI

The normal `ci` tag includes `zfs/mmap-write-truncate`. It uses the helper from
the exact pinned ZFS source and exercises valid writes, zero-progress EFAULT,
partial-prefix data integrity and subsequent destination access, directly on
ZFS and through OverlayFS. Kernel userfaultfd is enabled only in the test VM
to order source truncation between prefault and copy. The existing ZTS mmap
group also includes `mmap_write_truncate`.

**Runtime validation is pending.** No local tests, kernel/module builds or
VM runs were performed for the final source tuple after the publication-only
instruction. Earlier compile/style checks on a previous helper snapshot do
not qualify this tuple. CI completion is not awaited or claimed here.

Default OS CI builds the integration and runs the `ci`-tagged suite. The
full ZFS suite uses the separate `zfs-full` tag and is not automatically
covered by the normal CI selection. Historical before/after reproduction,
full ZTS, and 6.18 runtime coverage have not been run by this publication task.
Review those gaps alongside CI results before treating the sources as
runtime-qualified. Publication is not a deployment or a live repair of an
already blocked write.
