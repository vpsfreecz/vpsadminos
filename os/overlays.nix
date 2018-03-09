{lib}:

[
        (import ./overlays/osctl.nix)
        (import ./overlays/lxc.nix)
        (import ./overlays/zfs.nix)
        (import ./overlays/minify.nix)
] ++ lib.optionals (lib.pathExists ../../vpsadmin) [(import ./overlays/vpsadmin.nix)]
