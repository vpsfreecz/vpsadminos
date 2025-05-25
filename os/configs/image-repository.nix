{ config, pkgs, lib, ... }:
{
  services.osctl.image-repository.vpsadminos = {
    rebuildAll = true;

    vendors.vpsadminos = { defaultVariant = "minimal"; };
    defaultVendor = "vpsadminos";

    images = {
      almalinux = {
        "8" = { tags = [ "oldstable" ]; };
        "9" = { tags = [ "latest" "stable" ]; };

        "10-kitten" = { tags = [ "10-kitten" "kitten" ]; };
      };

      alpine = {
        "3.20" = {};
        "3.21" = { tags = [ "latest" "stable" ]; };
      };

      arch.rolling = { name = "arch"; tags = [ "latest" "stable" ]; };

      centos = {
        "9-stream" = { tags = [ "latest-9-stream" ]; };
        "10-stream" = { tags = [ "latest-10-stream" "latest-stream" ]; };
      };

      chimera.rolling = { name = "chimera"; tags = [ "latest" "stable" ]; };

      debian = {
        "10" = { tags = [ "oldoldstable" ]; };
        "11" = { tags = [ "oldstable" ]; };
        "12" = { tags = [ "latest" "stable" ]; };
        "testing" = { tags = [ "testing" ]; };
        "unstable" = { tags = [ "unstable" ]; };
      };

      devuan = {
        "4" = { tags = [ "oldstable" ]; };
        "5" = { tags = [ "latest" "stable" ]; };
      };

      fedora = {
        "41" = {};
        "42" = { tags = [ "latest" "stable" ]; };

        "rawhide" = { tags = [ "rawhide" ]; };
      };

      gentoo = {
        openrc = { tags = [ "latest" "stable" "latest-openrc" "stable-openrc" ]; };
        systemd = { tags = [ "latest-systemd" "stable-systemd" ]; };
        musl = { tags = [ "latest-musl" "stable-musl" ]; };
      };

      guix.rolling = { name = "guix"; tags = [ "latest" "stable" ]; };

      nixos = {
        "25.05" = { tags = [ "latest" "stable" ]; };
        "unstable" = { tags = [ "unstable" ]; };

        "25.05-impermanence" = { tags = [ "latest" "stable" ]; };
        "unstable-impermanence" = { tags = [ "unstable" ]; };
      };

      opensuse = {
        "leap-15.5" = {};
        "leap-15.6" = { tags = [ "latest" "stable" ]; };
        "tumbleweed" = { tags = [ "latest-tumbleweed" ]; };
      };

      rocky = {
        "8" = { tags = [ "oldstable" ]; };
        "9" = { tags = [ "latest" "stable" ]; };
      };

      ubuntu = {
        "18.04" = {};
        "20.04" = { tags = [ "oldoldlts" ]; };
        "22.04" = { tags = [ "oldlts" ]; };
        "24.04" = { tags = [ "stable" "lts" ]; };
        "24.10" = {};
        "25.04" = { tags = [ "latest" ]; };
      };

      void = {
        "glibc" = { tags = [ "latest" "stable" "latest-glibc" "stable-glibc" ]; };
        "musl" = { tags = [ "latest-musl" "stable-musl" ]; };
      };
    };

    garbageCollection = [
      {
        distribution = "almalinux";
        version = "10-kitten-\\d+";
        keep = 4;
      }
      {
        distribution = "arch";
        version = "\\d+";
        keep = 4;
      }
      {
        distribution = "centos";
        version = "9-stream-\\d+";
        keep = 4;
      }
      {
        distribution = "centos";
        version = "10-stream-\\d+";
        keep = 4;
      }
      {
        distribution = "chimera";
        version = "\\d+";
        keep = 4;
      }
      {
        distribution = "debian";
        version = "testing-\\d+";
        keep = 4;
      }
      {
        distribution = "debian";
        version = "unstable-\\d+";
        keep = 4;
      }
      {
        distribution = "fedora";
        version = "rawhide-\\d+";
        keep = 4;
      }
      {
        distribution = "gentoo";
        version = "openrc-\\d+";
        keep = 4;
      }
      {
        distribution = "gentoo";
        version = "systemd-\\d+";
        keep = 4;
      }
      {
        distribution = "gentoo";
        version = "musl-\\d+";
        keep = 4;
      }
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
