require 'json'

module OsCtld
  # osctld config file interface
  class Config
    class CpuScheduler
      # @return [Boolean]
      attr_reader :enable
      alias_method :enable?, :enable

      # @return [Integer]
      attr_reader :min_package_container_count_percent

      def initialize(cfg)
        @enable = cfg.fetch('enable', false)
        @min_package_container_count_percent = cfg.fetch('min_package_container_count_percent', 75)
      end
    end

    # @return [Array<String>]
    attr_reader :apparmor_paths

    # @return [String]
    attr_reader :ctstartmenu

    # @return [String]
    attr_reader :lxcfs

    # @return [Boolean]
    attr_reader :enable_lock_registry
    alias_method :enable_lock_registry?, :enable_lock_registry

    # @return [CpuScheduler]
    attr_reader :cpu_scheduler

    # @param path [String]
    def initialize(path)
      cfg = JSON.parse(File.read(path))

      @apparmor_paths = cfg.fetch('apparmor_paths', [])
      @ctstartmenu = cfg['ctstartmenu']
      @lxcfs = cfg['lxcfs']
      @enable_lock_registry = cfg.fetch('lock_registry', false)
      @cpu_scheduler = CpuScheduler.new(cfg.fetch('cpu_scheduler', {}))
    end
  end
end
