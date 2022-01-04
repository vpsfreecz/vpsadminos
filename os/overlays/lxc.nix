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
        version = "4.0.11";

        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "04588923955274e1fbbf98dfebf9f6ac68457d53";
          sha256 = "sha256:09psf77fzyx3f679jfszqbgsl3agkbq8haa2zpsbcazlhywi3g0s";
        };

        buildInputs = oldAttrs.buildInputs ++ [ glibc glibc.static ];
      });
}
