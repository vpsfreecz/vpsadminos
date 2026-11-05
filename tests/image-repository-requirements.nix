{
  distributions ? [ ],
}:
let
  # Shared with dist-config/nixos-resolvers. The impermanence upgrade test also
  # fetches 24.05/impermanence from the repository before its userspace switch.
  nixosResolvers = [
    {
      distribution = "nixos";
      version = "22.11";
      variant = "minimal";
    }
    {
      distribution = "nixos";
      version = "24.05";
      variant = "impermanence";
    }
  ];
in
{
  inherit nixosResolvers;

  # Repository fetch selectors in the CI suite. Omitted vendor/variant mean the
  # sealed catalog defaults; omitted architecture means x86_64. Keep this list
  # with changes to explicit suite selectors. Locally generated/skip-image CTs
  # and ct-image-fetch's intentional custom repositories are not dependencies.
  all =
    distributions
    # Plain ct new defaults to stable, including crashdump's sampled families.
    ++
      map
        (distribution: {
          inherit distribution;
          version = "stable";
        })
        [
          "almalinux"
          "alpine"
          "arch"
          "debian"
          "ubuntu"
        ]
    # Docker/Podman/Incus/Snap explicitly fetch latest; the other families and
    # fixed AlmaLinux/Ubuntu versions are already in distributions.all.
    ++
      map
        (distribution: {
          inherit distribution;
          version = "latest";
        })
        [
          "debian"
          "ubuntu"
        ]
    ++ nixosResolvers;
}
