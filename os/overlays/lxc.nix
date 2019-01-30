self: super:
{
  lxc =
    let
      libcap = super.libcap.overrideAttrs (oldAttrs: rec {
        postInstall = builtins.replaceStrings [ ''rm "$lib"/lib/*.a'' ] [ "" ]
                                              oldAttrs.postInstall;
      });

      lxc = super.callPackage <nixpkgs/pkgs/os-specific/linux/lxc/default.nix> {
        inherit libcap;
      };

    in
      lxc.overrideAttrs (oldAttrs: rec {
        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "2bac30f83f26433cf225212cd99f352065806ea7";
          sha256 = "0kdmc5q2gvhvihs97y2by8qig8k3xpr356b5nl7lm3b702x882pj";
        };

        buildInputs = oldAttrs.buildInputs ++ [ super.glibc super.glibc.static ];
      });
}
