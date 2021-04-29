require 'osctld/lockable'
require 'libosctl'

module OsCtld
  class AutoStart::State
    include Lockable
    include OsCtl::Lib::Utils::File

    # @return [Pool]
    attr_reader :pool

    # @param pool [Pool]
    # @return [AutoStart::State]
    def self.load(pool)
      st = new(pool)
      st.load
      st
    end

    # @param pool [Pool]
    def initialize(pool)
      @pool = pool
      @started_cts = []
      init_lock
    end

    # @param add [Assets::Definition::Scope]
    def assets(add)
      add.file(
        state_path,
        desc: 'Contains a list of auto-started containers',
        user: 0,
        group: 0,
        mode: 0700,
        optional: true,
      )
    end

    def load
      return unless File.exist?(state_path)

      File.open(state_path).each_line do |line|
        started_cts << line.strip
      end
    end

    # @param ct [Container]
    def set_started(ct)
      exclusively do
        next if started_cts.include?(ct.id)

        started_cts << ct.id
        save
      end
    end

    # @param ct [Container]
    # @return [Boolean]
    def is_started?(ct)
      inclusively do
        started_cts.include?(ct.id)
      end
    end

    # @param ct [Container]
    def clear(ct)
      exclusively do
        next unless started_cts.include?(ct.id)

        started_cts.delete(ct.id)
        save
      end
    end

    protected
    attr_reader :started_cts

    def save
      exclusively do
        regenerate_file(state_path, 0700) do |new|
          started_cts.each { |id| new.puts(id) }
        end
      end
    end

    def state_path
      File.join(pool.autostart_dir, 'started-cts.txt')
    end
  end
end
