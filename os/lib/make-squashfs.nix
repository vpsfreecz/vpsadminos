{
  lib,
  stdenv,
  gnutar,
  squashfsTools,
  closureInfo,

  # The root directory of the squashfs filesystem is filled with the
  # closures of the Nix store paths listed here.
  storeContents ? [ ],

  # Directory containing secret files that shouldn't be present in the nix
  # store. The directory's basename has to be `secrets`.
  secretsDir ? null,

  # Preserve source pathnames in the generated filesystem.
  noStrip ? false,

  # Compression parameters.
  # For zstd compression you can use [ "zstd" "-Xcompression-level" "10" ].
  comp ? [
    "zstd"
    "-Xcompression-level"
    "10"
  ],
}:

let
  compFlags = lib.escapeShellArgs (
    if comp == null then [ "-no-compression" ] else [ "-comp" ] ++ comp
  );
in
stdenv.mkDerivation {
  name = "squashfs.img";

  nativeBuildInputs = [
    squashfsTools
  ]
  ++ lib.optional noStrip gnutar;

  buildCommand = ''
    closureInfo=${closureInfo { rootPaths = storeContents; }}

    # Also include a manifest of the closures in a format suitable
    # for nix-store --load-db.
    cp $closureInfo/registration nix-path-registration

    ${lib.optionalString (secretsDir != null) ''
      mkdir secrets
      cp -rp ${secretsDir}/. secrets/
    ''}

    # Generate the squashfs image.
  ''
  + (
    if noStrip then
      ''
        set -o pipefail

        # mksquashfs -no-strip would repeatedly traverse the live /nix/store
        # parent directory and can race with concurrent Nix builds changing its
        # metadata.  Stream a tar archive into sqfstar instead, preserving the
        # /nix/store paths without asking mksquashfs to scan their parents.
        mkdir -p sqfs-root/nix/store
        chmod 0755 sqfs-root/nix
        chmod 1775 sqfs-root/nix/store

        tar --create --file - \
          --absolute-names \
          --transform='s#^/##S' \
          --numeric-owner --owner=0 --group=0 \
          --xattrs --xattrs-include='*' \
          -C "$PWD" nix-path-registration ${lib.optionalString (secretsDir != null) "secrets"} \
          -C sqfs-root nix \
          --files-from "$closureInfo/store-paths" \
        | sqfstar \
          -all-root -root-uid 0 -root-gid 0 -root-mode 0755 \
          -b 1048576 ${compFlags} \
          "$out"
      ''
    else
      ''
        mksquashfs nix-path-registration $(cat $closureInfo/store-paths) \
          ${lib.optionalString (secretsDir != null) "secrets"} \
          $out -keep-as-directory -all-root -b 1048576 ${compFlags}
      ''
  );
}
