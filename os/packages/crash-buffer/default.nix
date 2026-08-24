{
  lib,
  stdenv,
  coreutils,
}:
stdenv.mkDerivation {
  pname = "crash-buffer";
  version = "1";

  src = ./crash-buffer.c;
  dontUnpack = true;

  nativeInstallCheckInputs = [ coreutils ];

  buildPhase = ''
    runHook preBuild

    $CC -std=gnu11 -O2 -Wall -Wextra -Werror -o crash-buffer $src

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 crash-buffer $out/bin/crash-buffer

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    dd if=/dev/zero of="$workdir/input" bs=1024 count=600 status=none
    "$out/bin/crash-buffer" \
      --complete "$workdir/complete" \
      --timing output "$workdir/timings" \
      "$workdir/output" < "$workdir/input"
    cmp "$workdir/input" "$workdir/output"
    test -f "$workdir/complete"
    grep -Eq '^output [0-9]+$' "$workdir/timings"

    printf append | "$out/bin/crash-buffer" --append "$workdir/output"
    test "$(tail -c 6 "$workdir/output")" = append

    if printf fail | "$out/bin/crash-buffer" \
      --complete "$workdir/failed" "$workdir/missing/output"; then
      exit 1
    fi
    test ! -e "$workdir/failed"

    if printf fail | "$out/bin/crash-buffer" \
      --complete "$workdir/full" /dev/full; then
      exit 1
    fi
    test ! -e "$workdir/full"

    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Bounded streaming writer for crash report output";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
