{ config, lib, pkgs, utils, ... }@args:
with lib;
let
  shared = import ./shared.nix args;
  modArgs = args // { inherit shared; };

  users = import ./users.nix modArgs;
  groups = import ./groups.nix modArgs;
  containers = import ./containers.nix modArgs;
  repositories = import ./repositories.nix modArgs;
  idRanges = import ./id-ranges.nix modArgs;
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

      repositories = mkOption {
        type = types.attrsOf (types.submodule repositories.type);
        default = {};
        description = "Remote osctl repositories for container images";
      };

      idRanges = mkOption {
        type = types.attrsOf (types.submodule idRanges.type);
        default = {};
        description = ''
          ID ranges are used to track user/group ID allocations into user namespace maps.
          There is one default ID range on each pool, with the possibility of creating
          custom ID ranges. User namespace maps allocated from one ID range are guaranteed
          to be unique, i.e. no two containers can share the same user/group IDs, making
          them isolated.

          Created ID ranges cannot be declaratively modified. Delete them manually
          or using the garbage collector, then recreate them if changes are needed.
        '';
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

      destroyMethod = mkOption {
        type = types.enum [ "manual" "auto" ];
        default = "manual";
        description = ''
          If set to <literal>manual</literal>, the garbage collector has to be
          run manually for every pool by the user by calling script
          <literal>gc-sweep-‹pool</literal>. When set to <literal>auto</literal>,
          the garbage collector is run in the background by runit service
          <literal>gc-&lt;pool&gt;</literal>. Options
          <option>osctl.pools.&lt;pool&gt;.pure</option> and
          <option>osctl.pools.&lt;pool&gt;.destroyUndeclared</option> are honored
          in the automated mode. Destructive operations using the manual
          invocation have to be enabled using command-line options.
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
    (mapAttrsToList (name: pool: repositories.mkServices name pool.repositories) pools)
    ++
    (mapAttrsToList (name: pool: idRanges.mkServices name pool.idRanges) pools)
    ++
    (mapAttrsToList (name: pool: gc.mkService name pool) pools)
  );

  buildSystemPackages = pools: flatten (mapAttrsToList gc.systemPackages pools);
in
{
  ###### interface

  options = {
    osctl.pools = mkOption {
      type = types.attrsOf (types.submodule pool);
      default = {};
      description = "osctl pools to configure";
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.osctl.pools != {}) {
      runit.services = buildServices config.osctl.pools;
      environment.systemPackages = buildSystemPackages config.osctl.pools;
    })
  ];
}
