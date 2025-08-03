let
  pkgs = import <nixpkgs> { };

  module = pkgs.fetchFromGitHub {
    owner = "nix-community";
    repo = "impermanence";
    rev = "e337457502571b23e449bf42153d7faa10c0a562";
    sha256 = "sha256-C2sGRJl1EmBq0nO98TNd4cbUy20ABSgnHWXLIJQWRFA=";
  };
in
{
  stable = module;

  unstable = module;
}
