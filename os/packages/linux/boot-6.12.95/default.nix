{
  lib,
  runCommand,
  nix,
  util-linux,
  zstd,
  originalKernel,
}:
# A recipe is not a byte pin: this kernel generated a new module-signing key
# on every clean build. Restore the original outputs instead. Keep all DWARF:
# kpatch-build reads it when determining special-section entry sizes.
runCommand "linux-6.12.95-frozen-boot"
  {
    outputs = [
      "out"
      "dev"
    ];
    nativeBuildInputs = [
      nix
      zstd
      originalKernel.stdenv.cc
      # Also retain the original vmlinux's util-linux store reference.
      (lib.getBin util-linux)
    ]
    ++ originalKernel.nativeBuildInputs;
    buildInputs = originalKernel.buildInputs or [ ];
  }
  ''
    set -o pipefail

    outArchive() {
      cat ${./out.nar.zst.part-00} ${./out.nar.zst.part-01}
    }
    devArchive() {
      cat ${./dev.nar.zst.part-00} ${./dev.nar.zst.part-01} ${./dev.nar.zst.part-02}
    }

    # Verify the NARs before restoring anything. These are hashes of the actual
    # historical outputs, not hashes inferred from their producing derivation.
    test "$(outArchive | zstd -q -dc | sha256sum | cut -d ' ' -f 1)" = \
      fd2ab2d102fdc7ec176aba6f6d5b99e8a45f0d1b099ebfcdfab1054b494dd70e
    test "$(devArchive | zstd -q -dc | sha256sum | cut -d ' ' -f 1)" = \
      1b8ee65eed800b9ad10219936c50aa9b62fdae4f78ff9adcfaf2051eec40c229
    outArchive | zstd -q -dc | nix-store --restore "$out"
    devArchive | zstd -q -dc | nix-store --restore "$dev"

    # Generated build metadata names its old output locations. Relocate text
    # only; never rewrite vmlinux, module bytes, ELF symbols, notes or DWARF.
    oldOut=/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95
    oldDev=/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev
    find "$dev" -type d -exec chmod u+w {} +
    LC_ALL=C grep -IrlZF -e "$oldDev" -e "$oldOut" "$dev" > "$TMPDIR/kernel-metadata"
    while IFS= read -r -d "" file; do
      chmod u+w "$file"
      sed -i -e "s|$oldDev|$dev|g" -e "s|$oldOut|$out|g" "$file"
    done < "$TMPDIR/kernel-metadata"

    printf '%s  %s\n' \
      3265b29d00581f09f9f171342c24cc8c6872ac679aca01f5e3fdb33d7850c541 "$out/bzImage" \
      6e63a63c8fd2fbaa92a51fd5bbcbd002909b33e0fa70ba77163075ab2014c5ab "$dev/vmlinux" \
      | sha256sum --check --status
  ''
