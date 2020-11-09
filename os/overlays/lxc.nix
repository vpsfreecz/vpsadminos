self: super:
{
  lxc =
    let
      # Workaround for build failures, try to remove in the future
      glibc = super.glibc.overrideAttrs (oldAttrs: rec {
        NIX_CFLAGS_COMPILE = "-Wno-error=stringop-truncation";
      });

      libcap = super.libcap.overrideAttrs (oldAttrs: rec {
        postInstall = builtins.replaceStrings [ ''rm "$lib"/lib/*.a'' ] [ "" ]
                                              oldAttrs.postInstall;
      });

      lxc = super.callPackage <nixpkgs/pkgs/os-specific/linux/lxc/default.nix> {
        inherit libcap;
      };

    in
      lxc.overrideAttrs (oldAttrs: rec {
        version = "4.0.5";

        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "1a89153b18827fb15bdfab91bfa79af643facdba";
          sha256 = "sha256:04cdg5xyjx6l321wjrq3j5r8iiv65cc67km7b3bcjj6zn2vgr7j5";
        };

        buildInputs = oldAttrs.buildInputs ++ [ glibc glibc.static ];
      });
}
