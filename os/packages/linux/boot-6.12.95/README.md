# Frozen Linux 6.12.95 boot and ABI outputs

These compressed NARs preserve the already-shipped 6.12.95 kernel used to
qualify the cumulative livepatch. They are binary inputs, not rebuilds of a
same-version kernel. They do not select a new default kernel or release version.

The producing recipe is vpsAdminOS `c065fa2f8485399737e20e8ef9e44299d0766654`,
Linux source `vpsfreecz/linux` commit
`a2384967b90f24d2470c9eb15f0e66d938df7e08`, with the builtin ZFS recipe and
configuration reconstructed by `../boot-6.12.95.nix`. The matching source and
its licensing remain available through those immutable repositories and the
package recipe. The archived output paths were:

- `/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95`
- `/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev`

The original kernel enables `CONFIG_MODULE_SIG_ALL` and generates its signing
key during the build. Rebuilding the identical derivation is therefore not a
byte identity guarantee. In staging run 38625437864, the rebuilt guest contained
certificate `89a0df75822810628826fa91c31c2ff684103e02`, whereas the qualified
kernel contains `9b92775b8dc8bb75450d474a782fbc1ec64b61a6`. The livepatch service's
strict identity check must remain intact, rather than accept this rebuilt image.

## Format and integrity

Concatenate each family's numbered parts in order, then decompress with Zstd.
Parts are at most 64 MiB. The resulting stream is a standard Nix archive:

| Output | Uncompressed NAR SHA-256 |
| --- | --- |
| out | `fd2ab2d102fdc7ec176aba6f6d5b99e8a45f0d1b099ebfcdfab1054b494dd70e` |
| dev | `1b8ee65eed800b9ad10219936c50aa9b62fdae4f78ff9adcfaf2051eec40c229` |

`default.nix` checks these hashes before restoring the archives into new Nix
outputs. Generated **text** build metadata is relocated to the new output
paths, so external-module builds do not depend on the old store locations.
Binary files, especially `vmlinux`, are never rewritten or stripped. Its full
DWARF is required by kpatch-build; debug information is not expendable here.
Historical paths inside DWARF are retained as provenance, not runtime inputs.
The original compiler and build-tool dependencies remain declared.

The original GNU build ID is `7801779436291880089e3407e50e5813f80d76f1`.
The binary hashes checked after restoration/metadata relocation are:

- `bzImage`: `3265b29d00581f09f9f171342c24cc8c6872ac679aca01f5e3fdb33d7850c541`
- `vmlinux`: `6e63a63c8fd2fbaa92a51fd5bbcbd002909b33e0fa70ba77163075ab2014c5ab`

These are public kernel/ABI outputs. The original generated signing private
key is not included. The development tree was checked for signing-key files
and private-key PEM markers before archiving. Keep the original signing
configuration and the livepatch boot-image/notes guard unchanged.
