{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  bison,
  file,
  texinfo,
  ncurses,
  zlib,
  lzo,
  snappy,
  zstd,
  gmp,
  mpfr,
}:
stdenv.mkDerivation rec {
  pname = "crash";
  version = "9.0.1";

  src = fetchFromGitHub {
    owner = "crash-utility";
    repo = "crash";
    rev = version;
    sha256 = "1c9xqfn0lhj5z76yc3iibygvc6920drw14gh9g2jvwgyb2fkxvg7";
  };

  gdbSrc = fetchurl {
    url = "https://ftp.gnu.org/gnu/gdb/gdb-16.2.tar.gz";
    sha256 = "1y1p59sn3a9fws4cnd9j17nmp97sir0v0d3x5rssr01j0d5dmhdx";
  };

  nativeBuildInputs = [
    bison
    file
    texinfo
  ];

  buildInputs = [
    ncurses
    zlib
    lzo
    snappy
    zstd
    gmp
    mpfr
  ];

  enableParallelBuilding = true;

  postPatch = ''
    substituteInPlace gdb-16.2.patch --replace-fail "/bin/cat" "cat"
    cp ${./gdb-static-link.patch} gdb-static-link.patch

    substituteInPlace Makefile \
      --replace-fail \
        'patch -N -p0 -r- --fuzz=0 < ''${GDB}.patch; ' \
        'patch -N -p0 -r- --fuzz=0 < ''${GDB}.patch; patch -N -p0 -r- --fuzz=0 < gdb-static-link.patch; ' \
      --replace-fail \
        'patch -p0 < ''${GDB}.patch; ' \
        'patch -N -p0 < ''${GDB}.patch; patch -N -p0 < gdb-static-link.patch; '
  '';

  preBuild = ''
    cp ${gdbSrc} ./gdb-16.2.tar.gz
  '';

  makeFlags = [
    "lzo"
    "snappy"
    "zstd"
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 crash $out/bin/crash
    install -Dm644 crash.8 $out/share/man/man8/crash.8

    runHook postInstall
  '';

  meta = with lib; {
    description = "Linux kernel crash utility";
    homepage = "https://github.com/crash-utility/crash";
    license = licenses.gpl2Plus;
    platforms = platforms.linux;
  };
}
