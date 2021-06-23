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
        version = "4.0.10";

        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "37ed602958c19d424764bd3591be34e731b4cb23";
          sha256 = "sha256:0kw7m5hsijimhpyvmx4vbhg2xx0p69m95gnjfjs779201gw9ad4s";
        };

        buildInputs = oldAttrs.buildInputs ++ [ glibc glibc.static ];
      });
}
