{ config, lib, pkgs, utils, ... }@args:
with lib;
let
  shared = import ./shared.nix args;
  modArgs = args // { inherit shared; };

  users = import ./users.nix modArgs;
  groups = import ./groups.nix modArgs;
  containers = import ./containers.nix modArgs;
  gc = import ./garbage-collector.nix modArgs;

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

      pure = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Determines whether the pool contains only users, groups and containers
          declared by Nix configuration. Users, groups and containers that are
          not declared are deleted when found.

          WARNING: enabling this option will cause all manually created
          containers, groups and users to be irreversibly destroyed,
          with any data they contained.
        '';
      };

      destroyUndeclared = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Determines whether declarative users, groups and containers removed
          from Nix configuration should be deleted from the system or not.

          When turned off, undeclared containers are stopped, but not destroyed.
          When enabled, undeclared containers, groups and users are destroyed.

          WARNING: enabling this option is dangerous, as it will irreversibly
          destroy containers that are not defined by the current system. For
          example, if you temporarily roll back the system for whatever reason,
          containers that were not declared in the older version will be
          destroyed.
        '';
      };
    };
  };

  buildServices = pools: mkMerge (
    (mapAttrsToList (name: pool: users.mkServices name pool.users) pools)
    ++
    (mapAttrsToList (name: pool: groups.mkServices name pool.groups) pools)
    ++
    (mapAttrsToList (name: pool: containers.mkServices name pool.containers) pools)
    ++
    (mapAttrsToList (name: pool: gc.mkService name pool) pools)
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
