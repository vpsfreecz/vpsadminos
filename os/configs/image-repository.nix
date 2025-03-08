{ config, pkgs, lib, ... }:
let
  variants = [ "minimal cloudinit" ];

  gcVariants = filterAttrs: map (variant: filterAttrs // { inherit variant; }) variants;
in {
  services.osctl.image-repository.vpsadminos = {
    rebuildAll = true;

    vendors.vpsadminos = { defaultVariant = "minimal"; };
    defaultVendor = "vpsadminos";

    images = {
      almalinux = {
        "8" = { inherit variants; tags = [ "oldstable" ]; };
        "9" = { inherit variants; tags = [ "latest" "stable" ]; };

        "10-kitten" = { tags = [ "10-kitten" "kitten" ]; };
      };

      alpine = {
        "3.18" = { inherit variants; };
        "3.19" = { inherit variants; };
        "3.20" = { inherit variants; };
        "3.21" = { inherit variants; tags = [ "latest" "stable" ]; };
      };

      arch.rolling = { name = "arch"; inherit variants; tags = [ "latest" "stable" ]; };

      centos = {
        "9-stream" = { inherit variants; tags = [ "latest-9-stream" ]; };
        "10-stream" = { inherit variants; tags = [ "latest-10-stream" "latest-stream" ]; };
      };

      chimera.rolling = { name = "chimera"; tags = [ "latest" "stable" ]; };

      debian = {
        "10" = { inherit variants; tags = [ "oldoldstable" ]; };
        "11" = { inherit variants; tags = [ "oldstable" ]; };
        "12" = { inherit variants; tags = [ "latest" "stable" ]; };
        "testing" = { inherit variants; tags = [ "testing" ]; };
        "unstable" = { inherit variants; tags = [ "unstable" ]; };
      };

      devuan = {
        "4" = { tags = [ "oldstable" ]; };
        "5" = { tags = [ "latest" "stable" ]; };
      };

      fedora = {
        "40" = { inherit variants; };
        "41" = { inherit variants; tags = [ "latest" "stable" ]; };

        "rawhide" = { inherit variants; tags = [ "rawhide" ]; };
      };

      gentoo = {
        openrc = { inherit variants; tags = [ "latest" "stable" "latest-openrc" "stable-openrc" ]; };
        systemd = { inherit variants; tags = [ "latest-systemd" "stable-systemd" ]; };
        musl = { inherit variants; tags = [ "latest-musl" "stable-musl" ]; };
      };

      guix.rolling = { name = "guix"; tags = [ "latest" "stable" ]; };

      nixos = {
        "24.11" = { tags = [ "latest" "stable" ]; };
        "unstable" = { tags = [ "unstable" ]; };

        "24.11-impermanence" = { tags = [ "latest" "stable" ]; };
        "unstable-impermanence" = { tags = [ "unstable" ]; };
      };

      opensuse = {
        "leap-15.5" = { inherit variants; };
        "leap-15.6" = { inherit variants; tags = [ "latest" "stable" ]; };
        "tumbleweed" = { inherit variants; tags = [ "latest-tumbleweed" ]; };
      };

      rocky = {
        "8" = { inherit variants; tags = [ "oldstable" ]; };
        "9" = { inherit variants; tags = [ "latest" "stable" ]; };
      };

      slackware = {
        "15.0" = { tags = [ "latest" "stable" ]; };
        "current" = { tags = [ "latest-current" ]; };
      };

      ubuntu = {
        "18.04" = {};
        "20.04" = { inherit variants; tags = [ "oldoldlts" ]; };
        "22.04" = { inherit variants; tags = [ "oldlts" ]; };
        "24.04" = { inherit variants; tags = [ "stable" "lts" ]; };
        "24.10" = { inherit variants; tags = [ "latest" ]; };
      };

      void = {
        "glibc" = { tags = [ "latest" "stable" "latest-glibc" "stable-glibc" ]; };
        "musl" = { tags = [ "latest-musl" "stable-musl" ]; };
      };
    };

    garbageCollection = lib.flatten [
      {
        distribution = "almalinux";
        version = "10-kitten-\\d+";
        keep = 4;
      }
      (gcVariants {
        distribution = "arch";
        version = "\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "centos";
        version = "9-stream-\\d+";
        keep = 4;
      })
      {
        distribution = "chimera";
        version = "\\d+";
        keep = 4;
      }
      (gcVariants {
        distribution = "debian";
        version = "testing-\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "debian";
        version = "unstable-\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "fedora";
        version = "rawhide-\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "gentoo";
        version = "openrc-\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "gentoo";
        version = "systemd-\\d+";
        keep = 4;
      })
      (gcVariants {
        distribution = "gentoo";
        version = "musl-\\d+";
        keep = 4;
      })
      {
        distribution = "guix";
        version = "\\d+";
        keep = 4;
      }
      {
        distribution = "nixos";
        version = "unstable-\\d+";
        variant = "impermanence";
        keep = 4;
      }
      {
        distribution = "nixos";
        version = "unstable-\\d+";
        variant = "minimal";
        keep = 4;
      }
      {
        distribution = "opensuse";
        version = "tumbleweed-\\d+";
        keep = 4;
      }
      {
        distribution = "slackware";
        version = "current-\\d+";
        keep = 4;
      }
      {
        distribution = "void";
        version = "glibc-\\d+";
        keep = 4;
      }
      {
        distribution = "void";
        version = "musl-\\d+";
        keep = 4;
      }
    ];
  };
}
