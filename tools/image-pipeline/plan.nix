let
  source = builtins.getFlake (toString ../../.);
  lib = source.inputs.nixpkgs.lib;
  cfg =
    (import ../../os/configs/image-repository.nix {
      config = { };
      pkgs = { };
      inherit lib;
    }).services.osctl.image-repository.vpsadminos;
  entries = lib.flatten (
    lib.mapAttrsToList (
      distribution: versions:
      lib.mapAttrsToList (
        version: options:
        let
          name = options.name or "${distribution}-${version}";
          variants = options.variants or [ ];
        in
        map (variant: {
          name = name + lib.optionalString (variant != null) "#variant=${variant}";
          tags = options.tags or [ ];
        }) (if variants == [ ] then [ null ] else variants)
      ) versions
    ) cfg.images
  );
in
{
  items = lib.imap0 (
    order: item:
    item
    // {
      inherit order;
      id = "image-${toString order}";
    }
  ) entries;
  defaults = {
    default = cfg.defaultVendor;
  }
  // lib.mapAttrs (_: v: v.defaultVariant) cfg.vendors;
  gc = map (
    rule:
    {
      vendor = null;
      variant = null;
      arch = null;
      distribution = null;
      version = null;
    }
    // rule
  ) cfg.garbageCollection;
  dependencies =
    (import ../../tests/image-repository-requirements.nix {
      distributions = (import ../../tests/distributions.nix { inherit lib; }).all;
    }).all;
}
