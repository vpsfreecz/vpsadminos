{lib, vpsadmin}:
(import ./common.nix)
++
(lib.optionals (vpsadmin != null && (lib.isStorePath vpsadmin || lib.pathExists vpsadmin))
               [(import ./vpsadmin.nix vpsadmin)])
