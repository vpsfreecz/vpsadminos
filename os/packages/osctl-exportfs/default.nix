{ bash, bundlerApp, coreutils, iproute, lib, makeWrapper, nfs-utils, nix,
  runCommand, rpcbind, runit, util-linux }:
let
  app = bundlerApp {
    pname = "osctl-exportfs";
    gemdir = ./.;
    exes = [ "osctl-exportfs" ];

    meta = with lib; {
      description = "";
      homepage    = https://github.com/vpsfreecz/vpsadminos;
      license     = licenses.asl20;
      maintainers = [];
      platforms   = platforms.unix;
    };
  };

  runtimeDeps = [
    bash
    coreutils
    iproute
    nfs-utils
    nix
    rpcbind
    runit
    util-linux
  ];

  systemPath = lib.concatMapStringsSep ":" (pkg: "${pkg}/bin") runtimeDeps;
in runCommand app.name { buildInputs = [ makeWrapper ]; } ''
  mkdir -p $out/bin

  # Symlink everything except bin/
  for f in ${app}/* ; do
    name="$(basename "$f")"
    [ "$name" == bin ] && continue
    ln -sf "$f" $out/"$name"
  done

  # Wrap all executables in bin/ with runtime dependencies in PATH
  for exe in ${app}/bin/* ; do
    name="$(basename "$exe")"
    makeWrapper "$exe" $out/bin/"$name" --set PATH "${systemPath}"
  done
''
