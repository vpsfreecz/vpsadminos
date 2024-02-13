require 'osctld/lockable'
require 'libosctl'

module OsCtld
  # Stores a list of containers that are to be rebooted
  #
  # Containers can request reboot while osctld is shutting down, e.g. during
  # an update. During this time, we cannot fulfil reboot requests. We instead
  # store them in the runstate and will reboot them when osctld restarts.
  class AutoStart::Reboot
    include Lockable
    include OsCtl::Lib::Utils::File

    # @return [Pool]
    attr_reader :pool

    # @param pool [Pool]
    # @return [AutoStart::Reboot]
    def self.load(pool)
      st = new(pool)
      st.load
      st
    end

    # @param pool [Pool]
    def initialize(pool)
      @pool = pool
      @reboot_cts = []
      init_lock
    end

    # @param add [Assets::Definition::Scope]
    def assets(add)
      add.file(
        state_path,
        desc: 'Contains a list of containers to reboot',
        user: 0,
        group: 0,
        mode: 0o600,
        optional: true
      )
    end

    def load
      return unless File.exist?(state_path)

      File.open(state_path).each_line do |line|
        reboot_cts << line.strip
      end

      nil
    end

    # @param ct [Container]
    def add(ct)
      exclusively do
        next if reboot_cts.include?(ct.id)

        reboot_cts << ct.id
        save
      end

      nil
    end

    # @param ct [Container]
    def include?(ct)
      inclusively do
        reboot_cts.include?(ct.id)
      end
    end

    # @param ct [Container]
    def clear(ct)
      exclusively do
        i = reboot_cts.index(ct.id)
        next if i.nil?

        reboot_cts.delete_at(i)
        save
      end

      nil
    end

    def clear_all
      exclusively do
        reboot_cts.clear
        save
      end

      nil
    end

    protected

    attr_reader :reboot_cts

    def save
      exclusively do
        regenerate_file(state_path, 0o600) do |new|
          reboot_cts.each { |id| new.puts(id) }
        end
      end
    end

    def state_path
      File.join(pool.autostart_dir, 'reboot-cts.txt')
    end
  end
end
