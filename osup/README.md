osup
====

`osup` is a command line program managing system upgrades of vpsAdminOS. `osup`
handles upgrades and downgrades of `osctl`-managed data stored on ZFS pools.
This includes editing container/user/group configuration files, ZFS datasets
and other assets when some backward-incompatible change is introduced in
`osctld`.

`osup` is run by `osctld` when it import pools to ensure that the current
version of `osctld` is compatible with the data pools.

## Migrations
Migrations are the cornerstone of `osup`. Migrations are used to upgrade
the pool to a newer state, or rollback to an older state. Migrations are stored
as directories in [migrations/](migrations/):

    migrations/
    └── <timestamp>-<name>
        ├── spec.yml
        ├── up.rb
        └── down.rb

Each migration is identified by a timestamp: `YYYYMMDDHHIISS`, followed by
a dasherized name describing the migration. The migration is further described
in `spec.yml`, see below for its contents. `up.rb` is called for upgrade
and `down.rb` for downgrade.

### spec.yml
`spec.yml` is a file formatted in YAML:

```yaml
# Optional name, shown in `osup status`
name: i am a migration

description: |
  multiline string describing what
  the migration actually does

# Migrations can work on different parts of the pool. `snapshot` tells `osup`
# what datasets should be snapshot. Snapshots are used in case a migration fails
# to upgrade or rollback.
snapshot:
 - conf
 - log
 - hook
```

### up.rb, down.rb
`up.rb` and `down.rb` are Ruby scripts used to upgrade and rollback the
migration. These scripts can use whatever dependencies `osup` has. Each
migration should be tailored to the pool version it is supposed to work on.
Don't use functions whose behaviour can change over time based on other
migrations. Global variables:

 - `$MIGRATION_ID` - ID of the migration
 - `$POOL` - name of the ZFS pool to migrate
 - `$DATASET` - osctl root dataset on `$POOL`
