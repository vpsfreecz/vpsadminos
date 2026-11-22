# Retained image releases. The guest pin is independent of the host flake input.
let
  pin =
    release:
    {
      rev,
      narHash,
      lastModified,
    }:
    let
      github = {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
      };
    in
    {
      input = builtins.getFlake "github:NixOS/nixpkgs/${rev}?narHash=${narHash}";
      node = {
        # The image is reproducible; guests can still update within their release.
        original = github // {
          ref = "nixos-${release}";
        };
        locked = github // {
          inherit rev narHash lastModified;
        };
      };
    };
in
{
  "25.11" = pin "25.11" {
    rev = "b6018f87da91d19d0ab4cf979885689b469cdd41";
    narHash = "sha256-twXPFqFsrrY5r28Zh7Homgcp2gUMBgQ6WDS98Q/3xFI=";
    lastModified = 1782847189;
  };
  "26.05" = pin "26.05" {
    rev = "94c3211b0ee8ba969a3f12eb4aff8ba0f72971dd";
    narHash = "sha256-IEuDsf80ubivfpidbRsIm30HVo7PZIdZt1stRsbaY4Y=";
    lastModified = 1795258312;
  };
}
