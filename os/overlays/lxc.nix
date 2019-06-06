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
          rev = "ed1f8da39863574b762c18bc8c13f97b92561c08";
          sha256 = "1kwjxvxm0ay8cz9qffskw6dphr5kvy42cfqar7pz1banwf9rvqvn";
        };

        buildInputs = oldAttrs.buildInputs ++ [ super.glibc super.glibc.static ];
      });
}
