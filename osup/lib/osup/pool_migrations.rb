require 'libosctl'

module OsUp
  class PoolMigrations
    FILE = '/.migrations'

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :pool

    # @return [String] osctl root dataset on pool
    attr_reader :dataset

    # @return [String] mountpoint of osctl root dataset
    attr_reader :mountpoint

    # @return [String] path to file with a list of applied migrations
    attr_reader :version_file

    # @return [Array<Integer>]
    attr_reader :applied

    # @return [Array<Array>]
    attr_reader :all

    def initialize(pool)
      @pool = pool
      @applied = []
      @all = []

      load_pool
      load_applied
      build_list
    end

    # @param m [Migration]
    def applied?(m)
      @applied.include?(m.id)
    end

    # @yieldparam m [Migration, nil]
    def each(&)
      applied.lazy.map { |id| MigrationList[id] }.each(&)
    end

    def uptodate?
      all.detect { |_id, m| m && !applied?(m) } ? false : true
    end

    def upgradable?
      all.detect { |_id, m| m.nil? } ? false : true
    end

    # @param m [Migration]
    def set_up(m)
      applied << m.id
      save
      build_list
    end

    # @param m [Migration]
    def set_down(m)
      applied.delete(m.id)
      save
      build_list
    end

    # Mark all migrations as applied
    def set_all_up
      @applied = MigrationList.get.map(&:id)
      save
      build_list
    end

    def log_type
      "pool=#{pool}"
    end

    protected

    def load_pool
      mnt, active, ds = zfs(
        :get,
        '-Hp -ovalue mountpoint,org.vpsadminos.osctl:active,org.vpsadminos.osctl:dataset',
        pool
      ).output.strip.split

      raise "pool #{pool} is not used by osctld" if active != 'yes'

      if ds == '-'
        @dataset = pool
        @mountpoint = mnt
      else
        @dataset = ds
        @mountpoint = zfs(:get, '-Hp -ovalue mountpoint', ds).output.strip
      end

      @version_file = File.join(@mountpoint, FILE)
    end

    def load_applied
      File.open(version_file, 'r') do |f|
        f.each_line do |line|
          id = line.strip.to_i

          if id <= 0
            warn "invalid migration id '#{line}'"
            next
          end

          applied << id
        end
      end

      applied.uniq!
    rescue Errno::ENOENT
      # no migrations applied
    end

    # Build a list of all migrations, applied and unapplied and even those
    # that aren't recognized by `osup`
    def build_list
      @all = (MigrationList.get.map(&:id) + applied).sort.uniq.map do |id|
        [id, MigrationList[id]]
      end
    end

    def save
      regenerate_file(version_file, 0o600) do |new|
        applied.each { |id| new.puts(id) }
      end
    end
  end
end
