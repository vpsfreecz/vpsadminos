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
        version = "4.0.3";

        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "424a4000e8e001fa8ebba98d2feed6a1475997eb";
          sha256 = "sha256:01wza487861d1rbkv759k2r1rk2l1k0i4rb7xsz53zk27nrjg3b4";
        };

        buildInputs = oldAttrs.buildInputs ++ [ glibc glibc.static ];
      });
}
