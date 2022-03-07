self: super:
{
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
}
