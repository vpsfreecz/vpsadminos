{ vpsadminos }:
let
  # Source fixtures resolved from the official nixos-24.11 and nixos-25.11
  # branches on 2026-10-14. Keep production flake inputs and locks unchanged.
  historical =
    locked:
    let
      source = builtins.fetchTree (
        {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
        }
        // locked
      );
    in
    # getFlake requires a context-free locator. fetchTree has already fetched
    # and hash-verified this immutable source; only the locator loses context.
    builtins.getFlake (builtins.unsafeDiscardStringContext "path:${source.outPath}");
in
{
  "24.11" = historical {
    rev = "50ab793786d9de88ee30ec4e4c24fb4236fc2674";
    narHash = "sha256-/bVBlRpECLVzjV19t5KMdMFWSwKLtb5RyXdjz3LJT+g=";
  };
  "25.11" = historical {
    rev = "b6018f87da91d19d0ab4cf979885689b469cdd41";
    narHash = "sha256-twXPFqFsrrY5r28Zh7Homgcp2gUMBgQ6WDS98Q/3xFI=";
  };
  "26.05" = vpsadminos.inputs.nixpkgs;
  unstable = vpsadminos.inputs.nixpkgsUnstable;
}
