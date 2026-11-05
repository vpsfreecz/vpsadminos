url:
{
  config,
  options,
  lib,
  ...
}:
{
  # The runner also supports NixOS machines, which have no osctld options.
  config = lib.mkIf (options ? osctld) {
    osctld.settings.default_repository_url = url;
    osctl.pools = lib.mapAttrs (_: _: {
      repositories.default.url = url;
    }) config.boot.zfs.pools;
  };
}
