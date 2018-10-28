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
          rev = "44b80445dd8c6b8218afb62c56f752b418a858e8";
          sha256 = "19jkqmnr4ss5jmjdk7dr05bavd0d7jjimzlhfizr93wz7glzwp20";
        };

        buildInputs = oldAttrs.buildInputs ++ [ super.glibc super.glibc.static ];
      });
}
