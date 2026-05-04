{
  config,
  pkgs,
  lib,
  ...
}:
{
  services.osctl.image-repository.vpsadminos = {
    rebuildAll = true;

    vendors.vpsadminos = {
      defaultVariant = "minimal";
    };
    defaultVendor = "vpsadminos";

    images = {
      almalinux = {
        "8" = { };
        "9" = { };
        "10" = {
          tags = [
            "latest"
            "stable"
          ];
        };
      };

      alpine = {
        "3.20" = { };
        "3.21" = { };
        "3.22" = { };
        "3.23" = {
          tags = [
            "latest"
            "stable"
          ];
        };
      };

      arch.rolling = {
        name = "arch";
        tags = [
          "latest"
          "stable"
        ];
      };

      centos = {
        "9-stream" = {
          tags = [ "latest-9-stream" ];
        };
        "10-stream" = {
          tags = [
            "latest-10-stream"
            "latest-stream"
          ];
        };
      };

      chimera.rolling = {
        name = "chimera";
        tags = [
          "latest"
          "stable"
        ];
      };

      debian = {
        "11" = {
          tags = [ "oldstable" ];
        };
        "12" = {
          tags = [ "oldstable" ];
        };
        "13" = {
          tags = [
            "latest"
            "stable"
          ];
        };
        "testing" = {
          tags = [ "testing" ];
        };
        "unstable" = {
          tags = [ "unstable" ];
        };
      };

      devuan = {
        "5" = {
          tags = [ "oldstable" ];
        };
        "6" = {
          tags = [
            "latest"
            "stable"
          ];
        };
      };

      fedora = {
        "42" = { };
        "43" = { };
        "44" = {
          tags = [
            "latest"
            "stable"
          ];
        };

        "rawhide" = {
          tags = [ "rawhide" ];
        };
      };

      gentoo = {
        openrc = {
          tags = [
            "latest"
            "stable"
            "latest-openrc"
            "stable-openrc"
          ];
        };
        systemd = {
          tags = [
            "latest-systemd"
            "stable-systemd"
          ];
        };
        "musl-openrc" = {
          tags = [
            "latest-musl"
            "stable-musl"
            "latest-musl-openrc"
            "stable-musl-openrc"
          ];
        };
        "musl-systemd" = {
          tags = [
            "latest-musl-systemd"
            "stable-musl-systemd"
          ];
        };
      };

      guix.rolling = {
        name = "guix";
        tags = [
          "latest"
          "stable"
        ];
      };

      nixos = {
        "25.11" = {
          tags = [
            "latest"
            "stable"
          ];
        };
        "unstable" = {
          tags = [ "unstable" ];
        };

        "25.11-impermanence" = {
          tags = [
            "latest"
            "stable"
          ];
        };
        "unstable-impermanence" = {
          tags = [ "unstable" ];
        };
      };

      opensuse = {
        "leap-15.6" = { };
        "leap-16.0" = {
          tags = [
            "latest"
            "stable"
          ];
        };
        "tumbleweed" = {
          tags = [ "latest-tumbleweed" ];
        };
      };

      rocky = {
        "8" = { };
        "9" = { };
        "10" = {
          tags = [
            "latest"
            "stable"
          ];
        };
      };

      slackware = {
        "15.0" = {
          tags = [
            "latest"
            "stable"
          ];
        };
        "current" = {
          tags = [ "latest-current" ];
        };
      };

      ubuntu = {
        "18.04" = { };
        "20.04" = { };
        "22.04" = { };
        "24.04" = { };
        "25.04" = { };
        "25.10" = { };
        "26.04" = {
          tags = [
            "latest"
            "stable"
            "lts"
          ];
        };
      };

      void = {
        "glibc" = {
          tags = [
            "latest"
            "stable"
            "latest-glibc"
            "stable-glibc"
          ];
        };
        "musl" = {
          tags = [
            "latest-musl"
            "stable-musl"
          ];
        };
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
        distribution = "gentoo";
        version = "musl-openrc-\\d+";
        keep = 4;
      }
      {
        distribution = "gentoo";
        version = "musl-systemd-\\d+";
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
