{ config, lib, stdenv, fetchFromGitHub, pkg-config, meson, ninja, python3Packages
, help2man, fuse3, util-linux, makeWrapper
}:

with lib;
let
  python = python3Packages.python.withPackages (ps: [ ps.jinja2 ]);
in stdenv.mkDerivation rec {
  pname = "lxcfs";
  version = "5.0.4";

  src = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "lxcfs";
    rev = "a2ad76fcc422d2849e195728e30985bf527d210b";
    sha256 = "sha256-hM25lfhT9j9zaqej/aKtfvqivgWQ8RDKZs1ZruphS+U=";
  };

  nativeBuildInputs = [ pkg-config help2man meson ninja python makeWrapper ];

  buildInputs = [ fuse3 ];

  patchPhase = ''
    patchShebangs tools/meson-*
  '';

  mesonFlags = [
    "--localstatedir=/var"
    "-Dinit-script=sysvinit"
  ];

  postInstall = ''
    # `mount` hook requires access to the `mount` command from `util-linux`:
    wrapProgram "$out/share/lxcfs/lxc.mount.hook" \
      --prefix PATH : "${util-linux}/bin"

    # Remove unused init-script
    rm -rf $out/etc/init.d
  '';

  postFixup = ''
    # liblxcfs.so is reloaded with dlopen()
    patchelf --set-rpath "/run/current-system/sw/lib/lxcfs:$(patchelf --print-rpath "$out/bin/lxcfs"):$out/lib" "$out/bin/lxcfs"
  '';

  meta = {
    description = "FUSE filesystem for LXC";
    homepage = "https://linuxcontainers.org/lxcfs";
    changelog = "https://linuxcontainers.org/lxcfs/news/";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = with maintainers; [];
  };
}
