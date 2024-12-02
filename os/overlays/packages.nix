self: super:
{
  bird = super.bird.overrideAttrs (oldAttrs: rec {
    patches = super.bird.patches ++
      [ ../packages/bird/disable-kif-warnings-osrtr0.patch ];
    });

  devcgprog = super.callPackage ../packages/devcgprog {};

  goresheat = super.callPackage ../packages/goresheat {};

  irq_heatmap = super.callPackage ../packages/irq_heatmap {};

  ksvcmon = super.callPackage ../packages/ksvcmon {};

  lxc =
    let
      libcap = super.libcap.overrideAttrs (oldAttrs: rec {
        postInstall = builtins.replaceStrings [ ''rm "$lib"/lib/*.a'' ] [ "" ]
                                              oldAttrs.postInstall;
      });
    in super.callPackage ../packages/lxc/default.nix {
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

  scrubctl = super.callPackage ../packages/scrubctl {};

  vdevlog = super.callPackage ../packages/vdevlog {};
}
