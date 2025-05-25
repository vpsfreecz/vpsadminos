. "$IMAGEDIR/config.sh"
. "$INCLUDE/nixos.sh"

CHANNEL="nixos-$RELVER"
build-nixos

EXTRA_CONTAINER_CONFIG="
mounts:
- fs:
  mountpoint: \"/persistent\"
  type: bind
  opts: bind,create=dir,rw
  automount: true
  dataset: /
  temporary: false
- fs:
  mountpoint: \"/nix\"
  type: bind
  opts: bind,create=dir,rw
  automount: true
  dataset: nix
  temporary: false
impermanence:
  zfs_properties:
    refquota: 10G
"