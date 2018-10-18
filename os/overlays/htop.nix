self: super:
{
  htop = super.htop.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "htop";
      rev = "d64f7ab37e8965368aaa12285956f066d44c2727";
      sha256 = "1myk8cw9s3qmr5zpw8snbynr8rbwdjab2drha504spz9clmqa7gv";
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
