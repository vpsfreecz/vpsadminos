{ config, lib, pkgs, utils, ... }@args:
with lib;
let
  shared = import ./shared.nix args;
  modArgs = args // { inherit shared; };

  users = import ./users.nix modArgs;
  groups = import ./groups.nix modArgs;
  containers = import ./containers.nix modArgs;

  pool = {
    options = {
      parallelStart = mkOption {
        type = types.ints.positive;
        default = 2;
        description = ''
          Number of containers to start in parallel during pool import.
        '';
      };

      parallelStop = mkOption {
        type = types.ints.positive;
        default = 4;
        description = ''
          Number of containers to stop in parallel during pool export.
        '';
      };

      users = mkOption {
        type = types.attrsOf (types.submodule users.type);
        default = {};
        description = "osctl users to include";
      };

      groups = mkOption {
        type = types.attrsOf (types.submodule groups.type);
        default = {};
        description = ''
          osctl groups to include.

          In addition to groups defined by this options, there are always two
          groups present: <literal>/</literal> and <literal>/default</literal>.
        '';
      };

      containers = mkOption {
        type = types.attrsOf (types.submodule containers.type);
        default = {};
        description = "osctl containers to include";
      };
    };
  };

  buildServices = pools: mkMerge (
    (mapAttrsToList (name: pool: users.mkServices name pool.users) pools)
    ++
    (mapAttrsToList (name: pool: groups.mkServices name pool.groups) pools)
    ++
    (mapAttrsToList (name: pool: containers.mkServices name pool.containers) pools)
  );
in
{
  ###### interface

  options = {
    osctl.pools = mkOption {
      type = types.attrsOf (types.submodule pool);
      default = {};
      example = literalExample "";
      description = "osctl pools to configure";
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.osctl.pools != {}) {
      runit.services = buildServices config.osctl.pools;
    })
  ];
}
