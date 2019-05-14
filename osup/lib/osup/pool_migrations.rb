require 'libosctl'

module OsUp
  class PoolMigrations
    FILE = '/.migrations'

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :pool

    # @return [Array<Integer>]
    attr_reader :applied

    # @return [Array<Array>]
    attr_reader :all

    def initialize(pool)
      @pool = pool
      @applied = []
      @all = []

      load_applied
      build_list
    end

    # @param m [Migration]
    def applied?(m)
      @applied.include?(m.id)
    end

    # @yieldparam m [Migration, nil]
    def each(&block)
      applied.lazy.map { |id| MigrationList[id] }.each(&block)
    end

    def uptodate?
      all.detect { |id, m| m && !applied?(m) } ? false : true
    end

    def upgradable?
      all.detect { |id, m| m.nil? } ? false : true
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
      regenerate_file(version_file, 0600) do |new|
        applied.each { |id| new.puts(id) }
      end
    end

    def version_file
      return @version_file if @version_file

      mountpoint, active, dataset = zfs(
        :get,
        '-Hp -ovalue mountpoint,org.vpsadminos.osctl:active,org.vpsadminos.osctl:dataset',
        pool
      ).output.strip.split

      fail "pool #{pool} is not used by osctld" if active != 'yes'

      if dataset != '-'
        mountpoint = zfs(:get, '-Hp -ovalue mountpoint', dataset).output.strip
      end

      @version_file = File.join(mountpoint, FILE)
    end
  end
end
