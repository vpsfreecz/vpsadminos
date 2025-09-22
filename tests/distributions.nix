{ lib }:
let
  table = {
    alma_8 = {
      distribution = "almalinux";
      version = "8";
    };
    alma_9 = {
      distribution = "almalinux";
      version = "9";
    };
    alma_10 = {
      distribution = "almalinux";
      version = "10";
    };
    alpine = {
      distribution = "alpine";
      version = "latest";
    };
    arch = {
      distribution = "arch";
      version = "latest";
    };
    centos_7 = {
      distribution = "centos";
      version = "7";
    };
    centos_10_stream = {
      distribution = "centos";
      version = "latest-10-stream";
    };
    chimera = {
      distribution = "chimera";
      version = "latest";
    };
    debian_oldstable = {
      distribution = "debian";
      version = "oldstable";
    };
    debian_stable = {
      distribution = "debian";
      version = "stable";
    };
    debian_testing = {
      distribution = "debian";
      version = "testing";
    };
    devuan = {
      distribution = "devuan";
      version = "latest";
    };
    fedora = {
      distribution = "fedora";
      version = "latest";
    };
    gentoo_openrc = {
      distribution = "gentoo";
      version = "latest-openrc";
    };
    gentoo_systemd = {
      distribution = "gentoo";
      version = "latest-systemd";
    };
    gentoo_musl = {
      distribution = "gentoo";
      version = "latest-musl";
    };
    nixos_stable = {
      distribution = "nixos";
      version = "stable";
    };
    nixos_unstable = {
      distribution = "nixos";
      version = "unstable";
    };
    opensuse = {
      distribution = "opensuse";
      version = "latest";
    };
    rocky_8 = {
      distribution = "rocky";
      version = "8";
    };
    rocky_9 = {
      distribution = "rocky";
      version = "9";
    };
    rocky_10 = {
      distribution = "rocky";
      version = "10";
    };
    slackware = {
      distribution = "slackware";
      version = "latest";
    };
    ubuntu_2004 = {
      distribution = "ubuntu";
      version = "20.04";
    };
    ubuntu_2204 = {
      distribution = "ubuntu";
      version = "22.04";
    };
    ubuntu_2404 = {
      distribution = "ubuntu";
      version = "24.04";
    };
    void_glibc = {
      distribution = "void";
      version = "latest-glibc";
    };
    void_musl = {
      distribution = "void";
      version = "latest-musl";
    };
  };
in
{
  # Distributions that support both cgroups v1 and v2
  cgroupAll = with table; [
    alma_8
    alma_9
    alma_10
    alpine
    centos_10_stream
    chimera
    debian_oldstable
    debian_stable
    devuan
    fedora
    gentoo_systemd
    nixos_stable
    nixos_unstable
    opensuse
    rocky_8
    rocky_9
    rocky_10
    slackware
    ubuntu_2004
    ubuntu_2204
    ubuntu_2404
    void_glibc
    void_musl
  ];

  # Distributions that support only cgroups v2.
  # On hosts with cgroups v1, these distributions still mount /sys/fs/cgroup
  # as v2.
  cgroupv2 = with table; [
    arch
    debian_testing
  ];

  # Distributions that support only cgroups v1 and do not boot on hosts
  # with cgroups v2 at all.
  cgroupv1 = with table; [
    centos_7
  ];

  systemd = with table; [
    alma_8
    alma_9
    alma_10
    arch
    centos_10_stream
    debian_oldstable
    debian_stable
    debian_testing
    fedora
    gentoo_systemd
    nixos_stable
    nixos_unstable
    opensuse
    rocky_8
    rocky_9
    rocky_10
    ubuntu_2004
    ubuntu_2204
    ubuntu_2404
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
