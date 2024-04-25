self: super:
{
  bird = super.bird.overrideAttrs (oldAttrs: rec {
    patches = super.bird.patches ++
      [ ../packages/bird/disable-kif-warnings-osrtr0.patch ];
    });

  devcgprog = super.callPackage ../packages/devcgprog {};

  htop = super.htop.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "htop";
      rev = "251a450a9d52e221aeefbc85a43e0c47327774f2";
      sha256 = "sha256:1l9srlwbn5hqww9in5whbfx7rb28mqmh267fj4km68qvz38469vk";
    };

    nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [
      super.autoreconfHook
    ];

    preConfigure = ''
      sh autogen.sh
    '';

    configureFlags = [
      "--enable-vpsadminos"
    ];
  });

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
      systemd = null;
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
