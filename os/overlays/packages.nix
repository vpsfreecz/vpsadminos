self: super: {
  bird2 = super.bird2.overrideAttrs (oldAttrs: rec {
    patches = super.bird2.patches ++ [ ../packages/bird2/disable-kif-warnings-osrtr0.patch ];
  });

  ctptywrapper = super.callPackage ../packages/ctptywrapper { };

  devcgprog = super.callPackage ../packages/devcgprog { };

  goresheat = super.callPackage ../packages/goresheat { };

  irq_heatmap = super.callPackage ../packages/irq_heatmap { };

  ksvcmon = super.callPackage ../packages/ksvcmon { };

  libfastjson = super.libfastjson.overrideAttrs (oldAttrs: {
    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace Makefile.am \
        --replace-fail 'libfastjson_la_LIBADD = libfastjson-internal.la' \
                       'libfastjson_la_LIBADD = libfastjson-internal.la -lm'
    '';
  });

  prometheus-ebpf-exporter = super.callPackage ../packages/prometheus-ebpf-exporter { };

  lxc =
    let
      libcap = super.libcap.overrideAttrs (oldAttrs: rec {
        postInstall = builtins.replaceStrings [ ''rm "$lib"/lib/*.a'' ] [ "" ] oldAttrs.postInstall;
      });
    in
    super.callPackage ../packages/lxc/default.nix {
      inherit libcap;
      dbus = null;
    };

  mbuffer = super.mbuffer.overrideAttrs (oldAttrs: rec {
    version = "20211018";

    doCheck = false;

    src = super.fetchurl {
      url = "http://www.maier-komor.de/software/mbuffer/mbuffer-${version}.tgz";
      sha256 = "sha256:1qxnbpyly00kml3sjan9iqg6pqacsi3yqq66x25w455cwkjc2h72";
    };

    nativeBuildInputs = [ super.which ];
  });

  runit = super.runit.overrideAttrs (oldAttrs: rec {
    patches = [
      ../packages/runit/kexec-support.patch
      ../packages/runit/maxservices-100k.patch
    ];
  });

  scrubctl = super.callPackage ../packages/scrubctl { };

  sysinfo-to-json = super.callPackage ../packages/sysinfo-to-json { };

  vdevlog = super.callPackage ../packages/vdevlog { };

  write-boot-utmp = super.callPackage ../packages/write-boot-utmp { };
}
