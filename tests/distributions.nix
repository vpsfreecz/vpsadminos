{ lib }:
let
  table = {
    almalinux_8    = { distribution = "almalinux"; version = "8";             };
    alpine         = { distribution = "alpine";    version = "latest";        };
    arch           = { distribution = "arch";      version = "latest";        };
    centos_7       = { distribution = "centos";    version = "7";             };
    centos_stream  = { distribution = "centos";    version = "latest-stream"; };
    debian_10      = { distribution = "debian";    version = "10";            };
    debian_11      = { distribution = "debian";    version = "11";            };
    debian_testing = { distribution = "debian";    version = "testing";       };
    fedora         = { distribution = "fedora";    version = "latest";        };
    gentoo         = { distribution = "gentoo";    version = "latest";        };
    opensuse       = { distribution = "opensuse";  version = "latest";        };
    slackware      = { distribution = "slackware"; version = "latest";        };
    ubuntu_1604    = { distribution = "ubuntu";    version = "16.04";         };
    ubuntu_1804    = { distribution = "ubuntu";    version = "18.04";         };
    ubuntu_2004    = { distribution = "ubuntu";    version = "20.04";         };
    void_glibc     = { distribution = "void";      version = "latest-glibc";  };
    void_musl      = { distribution = "void";      version = "latest-musl";   };
  };
in {
  cgroupv2 = with table; [
    almalinux_8
    alpine
    arch
    centos_stream
    debian_10
    debian_11
    debian_testing
    fedora
    opensuse
    slackware
    ubuntu_1604
    ubuntu_1804
    ubuntu_2004
    void_glibc
    void_musl
  ];

  cgroupv1 = with table; [
    centos_7
  ];

  all = lib.mapAttrsToList (k: v: v) table;
}
