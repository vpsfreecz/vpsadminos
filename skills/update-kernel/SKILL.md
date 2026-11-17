---
name: update-kernel
description: Update a vpsAdminOS stable or unstable kernel selection, or add a selectable kernel version, while preserving the complete packaged downstream patch stack and Linux/ZFS pairing. Use for kernel version ports and catalog updates; numbered livepatch releases use manage-livepatch.
---

# Update a kernel

1. Read the repository [agent instructions](../../AGENTS.md), the
   [kernel update process](../../docs/os/kernel-updates.md) in full, and the
   [downstream patch-series policy](../../docs/os/patch-series-policy.md).
2. Establish the requested target, stable/unstable role and add-only or selector
   replacement intent. Derive the predecessor and complete downstream range from
   current package pins and upstream history on every run. Include patches
   without a product subject prefix and patches applied by the package builders.
3. Follow the process through semantic conflict resolution, complete old-to-new
   correspondence, final source publication, archive-byte hashing and catalog
   registration. When replacing a role, update its selector and verify the
   resolved Linux/ZFS identity; retain existing version entries.
4. Keep this run's exact refs, generated patch inventory, resolutions and results
   in its existing Markdown tracker. Use native Git/Nix/build/test interfaces;
   do not add a fixed patch inventory or a separate tracking/helper framework.

Final Linux delivery is the reviewed and verified exact head on
`vpsadminos-<upstream-version>`, without a Linux default/series merge or automatic
downstream tags. Keep the OS pin at the full commit and archive-byte hash. Follow
the process for existing-branch checks and publication proof; OS integration and
machine deployment retain their separate authorization and review rules.
