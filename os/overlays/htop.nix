self: super:
{
  htop = super.htop.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "htop";
      rev = "96de2f898977af132d505a9ff5ee47dd55c26031";
      sha256 = "1kgq2d5xpbmziffkx4dggkixa0815sjjc3c38z403074csljygly";
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
}
