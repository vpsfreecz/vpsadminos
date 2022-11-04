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

    class SendReceive
      # @return [Mbuffer]
      attr_reader :receive_mbuffer

      def initialize(cfg)
        @receive_mbuffer = Mbuffer.new(cfg.fetch('receive_mbuffer', {}))
      end
    end

    class Mbuffer
      # @return [String]
      attr_reader :block_size

      # @return [String]
      attr_reader :buffer_size

      # @return [Integer]
      attr_reader :start_writing_at

      # @return [Array<String>]
      attr_reader :as_cli_options

      def initialize(cfg)
        @block_size = cfg.fetch('block_size', '128k')
        @buffer_size = cfg.fetch('buffer_size', '256M')
        @start_writing_at = cfg.fetch('start_writing_at', 80)
        @as_cli_options = [
          '-s', block_size,
          '-m', buffer_size,
          '-P', start_writing_at.to_s,
        ]
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

    # @return [SendReceive]
    attr_reader :send_receive

    # @param path [String]
    def initialize(path)
      cfg = JSON.parse(File.read(path))

      @apparmor_paths = cfg.fetch('apparmor_paths', [])
      @ctstartmenu = cfg['ctstartmenu']
      @lxcfs = cfg['lxcfs']
      @enable_lock_registry = cfg.fetch('lock_registry', false)
      @cpu_scheduler = CpuScheduler.new(cfg.fetch('cpu_scheduler', {}))
      @send_receive = SendReceive.new(cfg.fetch('send_receive', {}))
    end
  end
end
