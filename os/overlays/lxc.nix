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
        version = "3.0.4";

        src = super.fetchFromGitHub {
          owner = "vpsfreecz";
          repo = "lxc";
          rev = "c29faa35f037833a2c0cd36176be22cde50357ab";
          sha256 = "0b5z6x2kcvq1sb0da4dw8gyh45j1jnq7i0fn1ns64i9y1jcgvjx5";
        };

        buildInputs = oldAttrs.buildInputs ++ [ super.glibc super.glibc.static ];
      });
}
