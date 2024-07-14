{ lib }:
let
  table = {
    alma_oldstable   = { distribution = "almalinux"; version = "oldstable";       };
    alma_stable      = { distribution = "almalinux"; version = "stable";          };
    alpine           = { distribution = "alpine";    version = "latest";          };
    arch             = { distribution = "arch";      version = "latest";          };
    centos_7         = { distribution = "centos";    version = "7";               };
    centos_9_stream  = { distribution = "centos";    version = "latest-9-stream"; };
    chimera          = { distribution = "chimera";   version = "latest";          };
    debian_oldstable = { distribution = "debian";    version = "oldstable";       };
    debian_stable    = { distribution = "debian";    version = "stable";          };
    debian_testing   = { distribution = "debian";    version = "testing";         };
    devuan           = { distribution = "devuan";    version = "latest";          };
    fedora           = { distribution = "fedora";    version = "latest";          };
    gentoo_openrc    = { distribution = "gentoo";    version = "latest-openrc";   };
    gentoo_systemd   = { distribution = "gentoo";    version = "latest-systemd";  };
    gentoo_musl      = { distribution = "gentoo";    version = "latest-musl";     };
    nixos_stable     = { distribution = "nixos";     version = "stable";          };
    nixos_unstable   = { distribution = "nixos";     version = "unstable";        };
    opensuse         = { distribution = "opensuse";  version = "latest";          };
    rocky_oldstable  = { distribution = "rocky";     version = "oldstable";       };
    rocky_stable     = { distribution = "rocky";     version = "stable";          };
    slackware        = { distribution = "slackware"; version = "latest";          };
    ubuntu_oldoldlts = { distribution = "ubuntu";    version = "oldoldlts";       };
    ubuntu_oldlts    = { distribution = "ubuntu";    version = "oldlts";          };
    ubuntu_lts       = { distribution = "ubuntu";    version = "lts";             };
    void_glibc       = { distribution = "void";      version = "latest-glibc";    };
    void_musl        = { distribution = "void";      version = "latest-musl";     };
  };
in {
  cgroupv2 = with table; [
    alma_oldstable
    alma_stable
    alpine
    arch
    centos_9_stream
    chimera
    debian_oldstable
    debian_stable
    debian_testing
    devuan
    fedora
    gentoo_systemd
    nixos_stable
    nixos_unstable
    opensuse
    rocky_oldstable
    rocky_stable
    slackware
    ubuntu_oldoldlts
    ubuntu_oldlts
    ubuntu_lts
    void_glibc
    void_musl
  ];

  cgroupv1 = with table; [
    centos_7
  ];

  systemd = with table; [
    alma_oldstable
    alma_stable
    arch
    centos_7
    centos_9_stream
    debian_oldstable
    debian_stable
    debian_testing
    fedora
    gentoo_systemd
    nixos_stable
    nixos_unstable
    opensuse
    rocky_oldstable
    rocky_stable
    ubuntu_oldoldlts
    ubuntu_oldlts
    ubuntu_lts
  ];

  non-systemd = with table; [
    alpine
    chimera
    devuan
    gentoo_openrc
    gentoo_musl
    slackware
    void_glibc
    void_musl
  ];

  all = lib.mapAttrsToList (k: v: v) table;
}
