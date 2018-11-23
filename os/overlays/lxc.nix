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
          rev = "2063f5387178d29085f946d1eaf99346352c9fa3";
          sha256 = "1nl6an18rg6m21sl8ajn7xq9b0g82v7w8wg95wh2yjpzq9kj50vl";
        };

        buildInputs = oldAttrs.buildInputs ++ [ super.glibc super.glibc.static ];
      });
}
