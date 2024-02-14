module OsUp
  class Migrator
    # Prepare a list of migrations to be run for upgrade
    # @param pool_migrations [PoolMigrations]
    # @param opts [Hash]
    # @option opts [Integer] :to target migration id
    # @return [Array<Migration>] ordered list of migrations to up
    def self.upgrade_sequence(pool_migrations, **opts)
      available = pool_migrations.all

      # Find the last applied migration
      i = available.index do |id, m|
        if m.nil?
          raise "unable to upgrade pool #{pool_migrations.pool}: " \
                "unrecognized migration #{id}"
        end

        !pool_migrations.applied?(m)
      end

      # List of migrations to apply
      list = available[i..]

      # Check that the list is clean
      list.each do |id, m|
        if m.nil?
          raise "unable to upgrade pool #{pool_migrations.pool}: " \
                "unrecognized migration #{id}"
        end
      end

      # Verify that target version is reachable
      if opts[:to]
        j = list.index { |id, _m| id == opts[:to] }

        if j.nil?
          raise "unable to upgrade pool #{pool_migrations.pool}: " \
                "target migration #{opts[:to]} not found or reachable"
        end

        list = list[0..j]
      end

      # Convert to a list of migrations
      list.map { |_id, m| m }
    end

    # @param pool_migrations [PoolMigrations]
    # @param opts [Hash]
    # @option opts [Integer] :to target migration id
    # @option opts [Boolean] :dry_run
    def self.upgrade(pool_migrations, **opts)
      mapped = upgrade_sequence(pool_migrations, **opts)

      if opts[:dry_run]
        mapped.each do |m|
          puts "> would up #{m.id}"
        end

        return
      end

      migrator = new(pool_migrations, mapped)
      migrator.run(:up)
    end

    # Prepare a list of migrations to be run for rollback
    # @param pool_migrations [PoolMigrations]
    # @param opts [Hash]
    # @option opts [Integer] :to target migration id
    # @return [Array<Migration>] ordered list of migrations to down
    def self.rollback_sequence(pool_migrations, **opts)
      available = pool_migrations.all

      # Find the last applied migration
      i = available.rindex do |id, m|
        if m.nil?
          raise "unable to rollback pool #{pool_migrations.pool}: " \
                "unrecognized migration #{id}"
        end

        pool_migrations.applied?(m)
      end

      if i.nil?
        raise "unable to rollback pool #{pool_migrations.pool}: " \
              'no applied migration found'
      end

      # List of applied migrations
      applied = available[0..i].reverse

      if opts[:to]
        # Find the target version
        j = applied.index do |id, m|
          if m.nil?
            raise "unable to rollback pool #{pool_migrations.pool}: " \
                  "unrecognized migration #{id}"
          end

          id == opts[:to]
        end

        if j.nil?
          raise "unable to rollback pool #{pool_migrations.pool}: " \
                "migration #{opts[:to]} not found or reacheable"

        elsif j == 0
          raise "unable to rollback pool #{pool_migrations.pool}: " \
                "would rollback migration #{id}, but it is set as the target"
        end

        list = applied[0..j - 1]

      else
        list = [applied.first]
      end

      # Convert to a list of migrations
      list.map { |_id, m| m }
    end

    # @param pool_migrations [PoolMigrations]
    # @param opts [Hash]
    # @option opts [Integer] :to target migration id
    # @option opts [Boolean] :dry_run
    def self.rollback(pool_migrations, **opts)
      mapped = rollback_sequence(pool_migrations, **opts)

      if opts[:dry_run]
        mapped.each do |m|
          puts "> would down #{m.id}"
        end

        return
      end

      migrator = new(pool_migrations, mapped)
      migrator.run(:down)
    end

    # @param pool_migrations [PoolMigrations]
    # @param queue [Array<Migration>] ordered list of migrations to up/down
    def initialize(pool_migrations, queue)
      @pool_migrations = pool_migrations
      @queue = queue
    end

    # @param action [:up, :down]
    def run(action)
      queue.each do |m|
        puts "> #{action} #{m.id} - #{m.name}"

        raise "migration #{m.id} returned non-zero exit status" unless run_migration(m, action)

        pool_migrations.send("set_#{action}", m)
      end

      true
    end

    protected

    attr_reader :pool_migrations, :queue

    def run_migration(m, action)
      state = SystemState.create(
        pool_migrations.dataset,
        "#{m.id}-#{action}",
        snapshot: m.snapshot
      )

      pid = Process.fork do
        ENV.keep_if do |k, _v|
          %w[GLI_DEBUG HOME LANG LOGNAME PATH PWD USER].include?(k)
        end

        # osup is intentionally run from /run/current-system, as we don't want
        # to call it from within the osctld or any other gem bundle. osup needs
        # to be independent, so that it's environment and dependencies are clear.
        Process.exec(
          '/run/current-system/sw/bin/osup', 'run',
          pool_migrations.pool, pool_migrations.dataset, m.dirname, action.to_s
        )
      end

      Process.wait(pid)

      if $?.exitstatus == 0
        state.commit
        true
      else
        state.rollback
        false
      end
    end
  end
end
