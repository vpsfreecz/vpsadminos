pkgs: {
  config = {
    imports = [ ../../configs/vpsadminos/base.nix ];

    boot.zfs.pools = { };
  };
}
