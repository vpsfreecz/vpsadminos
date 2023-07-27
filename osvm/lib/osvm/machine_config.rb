require 'json'
require 'securerandom'

module OsVm
  class MachineConfig
    class Cpu
      # @return [Integer]
      attr_reader :cores

      # @return [Integer]
      attr_reader :threads

      # @return [Integer]
      attr_reader :sockets

      def initialize(cfg)
        @cores = cfg.fetch(:cores)
        @threads = cfg.fetch(:threads)
        @sockets = cfg.fetch(:sockets)
      end
    end

    class Disk
      # @return [String]
      attr_reader :device

      # @return ['file', 'blockdev']
      attr_reader :type

      # @return [String]
      attr_reader :size

      # @return [Boolean]
      attr_reader :create

      def initialize(cfg)
        @device = cfg.fetch(:device)
        @type = cfg.fetch(:type)

        unless %w(file blockdev).include?(@type)
          raise ArgumentError, "unsupported disk type #{@type.inspect}"
        end

        @size = cfg.fetch(:size)
        @create = cfg.fetch(:create, true)
      end
    end

    class Network
      # @return [Network]
      def self.from_config(cfg)
        mode = cfg.fetch(:mode)
        klass =
          case mode
          when 'user'
            UserNetwork
          when 'bridge'
            BridgeNetwork
          else
            raise ArgumentError, "unknown network mode #{mode.inspect}"
          end

        klass.new(cfg)
      end

      # @return [String]
      attr_reader :mode

      def initialize(cfg)
        @mode = cfg.fetch(:mode)
        @opts = cfg.fetch(:opts, {})
      end

      def qemu_options
        raise NotImplementedError
      end
    end

    class UserNetwork < Network
      def qemu_options
        net_opts = "net=#{@opts.fetch(:network)},host=#{@opts.fetch(:host)},dns=#{@opts.fetch(:dns)}"
        net_opts << ",hostfwd=#{@opts[:hostForward]}" if @opts[:hostForward]

        [
          "-device", "virtio-net,netdev=net0",
          "-netdev", "user,id=net0,#{net_opts}",
        ]
      end
    end

    class BridgeNetwork < Network
      # @return [String]
      attr_reader :link

      # @return [String]
      attr_reader :mac

      def initialize(cfg)
        super
        @link = @opts.fetch(:link)
        @mac = gen_mac_address
      end

      def qemu_options
        [
          "-device", "virtio-net,netdev=net1,mac=#{@mac}",
          "-netdev", "bridge,id=net1,br=#{link}",
        ]
      end

      protected
      def gen_mac_address
        "00:60:2f:#{SecureRandom.hex(3).chars.each_slice(2).map(&:join).join(':')}"
      end
    end

    # Load machine config from file
    # @param path [String]
    # @return [MachineConfig]
    def self.load_file(path)
      cfg = JSON.parse(File.read(path), symbolize_names: true)
      new(cfg)
    end

    # @return [String] path to qemu package
    attr_reader :qemu

    # @return [Array<String>]
    attr_reader :extra_qemu_options

    # @return [String] path to virtiofsd package
    attr_reader :virtiofsd

    # @return [String] path to squashfs rootfs image
    attr_reader :squashfs

    # @return [String] path to kernel bzImage
    attr_reader :kernel

    # @return [String] path to initrd
    attr_reader :initrd

    # @return [Array<String>] kernel parameters
    attr_reader :kernel_params

    # @return [String] path to system top level
    attr_reader :toplevel

    # @return [Array<Disk>]
    attr_reader :disks

    # @return [Integer] system memory in MiB
    attr_reader :memory

    # @return [Integer]
    attr_reader :cpus

    # @return [Cpu]
    attr_reader :cpu

    # @return [Hash<String, String>] fs name => host directory
    attr_reader :shared_filesystems

    # @return [Network]
    attr_reader :network

    # @param cfg [Hash]
    def initialize(cfg)
      @qemu = cfg.fetch(:qemu)
      @extra_qemu_options = cfg.fetch(:extraQemuOptions, [])
      @virtiofsd = cfg.fetch(:virtiofsd)
      @squashfs = cfg.fetch(:squashfs)
      @kernel = cfg.fetch(:kernel)
      @initrd = cfg.fetch(:initrd)
      @kernel_params = cfg.fetch(:kernelParams)
      @toplevel = cfg.fetch(:toplevel)
      @disks = cfg.fetch(:disks).map { |disk_cfg| Disk.new(disk_cfg) }
      @memory = cfg.fetch(:memory)
      @cpus = cfg.fetch(:cpus)
      @cpu = Cpu.new(cfg.fetch(:cpu))
      @shared_filesystems = cfg.fetch(:sharedFileSystems, {})
      @network = Network.from_config(cfg.fetch(:network, {
        mode: 'user',
        opts: {
          network: '10.0.2.0/24',
          host: '10.0.2.2',
          dns: '10.0.2.3',
        },
      }))
    end
  end
end
