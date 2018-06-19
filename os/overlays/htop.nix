self: super:
{
  htop = super.htop.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "htop";
      rev = "328f7bb4caa682b10988e2c99116daddf65184ce";
      sha256 = "1hnyvyw6vl19vdshg12fbnfw18x85fn5ahzjn16y0gwj3lgbphrr";
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
