pkgs: {
  config = {
    imports = [ ../configs/base.nix ];

    boot.zfs.pools = {};
  };
}
