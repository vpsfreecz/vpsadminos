require 'json'

module OsCtld
  # osctld config file interface
  class Config
    class CpuScheduler
      # @return [Boolean]
      attr_reader :enable
      alias enable? enable

      # @return [Integer]
      attr_reader :min_package_container_count_percent

      # @return [Hash<Integer, CpuPackage>]
      attr_reader :packages

      # Containers with priority beneath this threshold are put on the second
      # CPU package on systems with two CPU packages if sequential start/stop
      # is enabled. Containers with priority equal or higher than the threshold
      # might be started out of priority order on systems with two CPU packages.
      #
      # Note that all thus prioritized containers will be put on the second CPU
      # package, and so it is possible to cause imbalance in CPU usage if all
      # the containers are heavy CPU users.
      # @return [Integer]
      attr_reader :sequential_start_priority_threshold

      def initialize(cfg)
        @enable = cfg.fetch('enable', false)
        @min_package_container_count_percent = cfg.fetch('min_package_container_count_percent', 90)
        @packages = cfg.fetch('packages', {}).to_h do |k, v|
          pkg = CpuPackage.new(k, v)
          [pkg.id, pkg]
        end

        @sequential_start_priority_threshold = cfg.fetch('sequential_start_priority_threshold', 1000)
      end
    end

    class CpuPackage
      # @return [Integer]
      attr_reader :id

      # @return [Boolean]
      attr_reader :enable
      alias enable? enable

      # @return [OsCtl::Lib::CpuMask]
      attr_reader :cpu_mask

      def initialize(id, cfg)
        @id = id.to_i
        @enable = cfg.fetch('enable', true)
        @cpu_mask = OsCtl::Lib::CpuMask.new(cfg.fetch('cpu_mask', '*'))
      end
    end

    class SendReceive
      # @return [Mbuffer]
      attr_reader :send_mbuffer

      # @return [Mbuffer]
      attr_reader :receive_mbuffer

      def initialize(cfg)
        @send_mbuffer = Mbuffer.new(cfg.fetch('send_mbuffer', {
          'start_writing_at' => 5
        }))
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

      # @return [Hash]
      attr_reader :as_hash_options

      def initialize(cfg)
        @block_size = cfg.fetch('block_size', '128k')
        @buffer_size = cfg.fetch('buffer_size', '256M')
        @start_writing_at = cfg.fetch('start_writing_at', 80)
        @as_cli_options = [
          '-s', block_size,
          '-m', buffer_size,
          '-P', start_writing_at.to_s
        ]
        @as_hash_options = {
          block_size:,
          buffer_size:,
          start_writing_at:
        }
      end
    end

    class TrashBin
      # @return [Integer] number of seconds between prunes
      attr_reader :prune_interval

      def initialize(cfg)
        @prune_interval = cfg.fetch('prune_interval', 6 * 60 * 60)
      end
    end

    # Enable extra debug logs
    # @return [Boolean]
    attr_reader :debug
    alias debug? debug

    # @return [Array<String>]
    attr_reader :apparmor_paths

    # @return [String]
    attr_reader :ctstartmenu

    # @return [Boolean]
    attr_reader :enable_lock_registry
    alias enable_lock_registry? enable_lock_registry

    # @return [CpuScheduler]
    attr_reader :cpu_scheduler

    # @return [SendReceive]
    attr_reader :send_receive

    # @return [TrashBin]
    attr_reader :trash_bin

    # @param path [String]
    def initialize(path)
      cfg = JSON.parse(File.read(path))

      @debug = cfg.fetch('debug', false)
      @apparmor_paths = cfg.fetch('apparmor_paths', [])
      @ctstartmenu = cfg['ctstartmenu']
      @enable_lock_registry = cfg.fetch('lock_registry', false)
      @cpu_scheduler = CpuScheduler.new(cfg.fetch('cpu_scheduler', {}))
      @send_receive = SendReceive.new(cfg.fetch('send_receive', {}))
      @trash_bin = TrashBin.new(cfg.fetch('trash_bin', {}))
    end
  end
end
