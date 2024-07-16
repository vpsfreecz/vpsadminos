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
      };

      alpine = {
        "3.17" = {};
        "3.18" = {};
        "3.19" = {};
        "3.20" = { tags = [ "latest" "stable" ]; };
      };

      arch.rolling = { name = "arch"; tags = [ "latest" "stable" ]; };

      centos = {
        "7" = {};
        "8-stream" = { tags = [ "latest-8-stream" "latest" "stable" ]; };
        "9-stream" = { tags = [ "latest-9-stream" "latest-stream" ]; };
      };

      chimera.rolling = { tags = [ "latest" "stable" ]; };

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
        "39" = {};
        "40" = { tags = [ "latest" "stable" ]; };
      };

      gentoo = {
        openrc = { tags = [ "latest" "stable" "latest-openrc" "stable-openrc" ]; };
        systemd = { tags = [ "latest-systemd" "stable-systemd" ]; };
        musl = { tags = [ "latest-musl" "stable-musl" ]; };
      };

      guix.rolling = { name = "guix"; tags = [ "latest" "stable" ]; };

      nixos = {
        "24.05" = { tags = [ "latest" "stable" ]; };
        "unstable" = { tags = [ "unstable" ]; };
      };

      opensuse = {
        "leap-15.4" = {};
        "leap-15.5" = { tags = [ "latest" "stable" ]; };
        "tumbleweed" = { tags = [ "latest-tumbleweed" ]; };
      };

      rocky = {
        "8" = { tags = [ "oldstable" ]; };
        "9" = { tags = [ "latest" "stable" ]; };
      };

      slackware = {
        "15.0" = { tags = [ "latest" "stable" ]; };
        "current" = { tags = [ "latest-current" ]; };
      };

      ubuntu = {
        "18.04" = { tags = [ "oldoldlts" ]; };
        "20.04" = { tags = [ "oldlts" ]; };
        "22.04" = { tags = [ "oldlts" ]; };
        "24.04" = { tags = [ "latest" "stable" "lts" ]; };
      };

      void = {
        "glibc" = { tags = [ "latest" "stable" "latest-glibc" "stable-glibc" ]; };
        "musl" = { tags = [ "latest-musl" "stable-musl" ]; };
      };
    };

    garbageCollection = [
      {
        distribution = "arch";
        version = "\\d+";
        keep = 4;
      }
      {
        distribution = "centos";
        version = "8-stream-\\d+";
        keep = 4;
      }
      {
        distribution = "centos";
        version = "9-stream-\\d+";
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
