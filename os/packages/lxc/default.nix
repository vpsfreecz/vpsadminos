{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  perl,
  docbook2x,
  docbook_xml_dtd_45,
  pam,
  glibc,
  openssl,

  # Optional Dependencies
  libapparmor ? null,
  gnutls ? null,
  libselinux ? null,
  libseccomp ? null,
  libcap ? null,
  dbus ? null,
}:

with lib;
stdenv.mkDerivation rec {
  pname = "lxc";
  version = "6.0.5";

  src = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "lxc";
    rev = "eb81116ab547ba0828b1bd9686fcc4648f9ddf78";
    sha256 = "sha256-D3pPY8HG16FbQ91V//EuweHEYoMPhDoGQb3nR60QbrY=";
  };

  nativeBuildInputs = [
    pkg-config
    meson
    ninja
    docbook2x
  ];

  buildInputs = [
    pam
    libapparmor
    gnutls
    libselinux
    libseccomp
    libcap
    openssl
    glibc
    glibc.static
  ];

  patchPhase = ''
    # Do not create empty directories in localstatedir
    sed -i '/install_emptydir/d' meson.build

    # Fix install path of bash completions
    sed -i "s|^bashcompletiondir =.*|bashcompletiondir = join_paths('$out', 'share', 'bash-completion', 'completions')|" meson.build

    # Prevent installation of README into rootfs mount path in /var
    sed -i 's/install: true/install: false/' doc/rootfs/meson.build
  '';

  mesonFlags = [
    "--localstatedir=/var"
    "-Ddistrosysconfdir=${placeholder "out"}/etc/default"
    "-Dusernet-config-path=/etc/lxc/lxc-usernet"
    "-Dpam-cgroup=true"
    "-Dinit-script=sysvinit"
    (if isNull dbus then "-Ddbus=false" else "-Ddbus=true")
  ]
  ++ optional (libapparmor != null) "-Dapparmor=true"
  ++ optional (libselinux != null) "-Dselinux=true"
  ++ optional (libseccomp != null) "-Dseccomp=true"
  ++ optional (libcap != null) "-Dcapabilities=true"
  ++ [
    "-Dexamples=false"
    (if doCheck then "-Dtests=true" else "-Dtests=false")
    "-Drootfs-mount-path=/var/lib/lxc/rootfs"
  ];

  postInstall = ''
    # Remove unused init-script
    rm -rf $out/etc/init.d
  '';

  doCheck = false;

  meta = {
    homepage = "https://linuxcontainers.org/";
    description = "Userspace tools for Linux Containers, a lightweight virtualization system";
    license = licenses.lgpl21Plus;

    longDescription = ''
      LXC is the userspace control package for Linux Containers, a
      lightweight virtual system mechanism sometimes described as
      "chroot on steroids". LXC builds up from chroot to implement
      complete virtual systems, adding resource management and isolation
      mechanisms to Linux’s existing process management infrastructure.
    '';

    platforms = platforms.linux;
    maintainers = with maintainers; [ ];
  };
}
