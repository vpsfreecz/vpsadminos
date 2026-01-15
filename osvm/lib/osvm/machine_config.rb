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
        @cores = cfg.fetch('cores')
        @threads = cfg.fetch('threads')
        @sockets = cfg.fetch('sockets')
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
        @device = cfg.fetch('device')
        @type = cfg.fetch('type')

        unless %w[file blockdev].include?(@type)
          raise ArgumentError, "unsupported disk type #{@type.inspect}"
        end

        @size = cfg.fetch('size')
        @create = cfg.fetch('create', true)
      end
    end

    class Network
      # @return [Network]
      def self.from_config(i, cfg)
        type = cfg.fetch('type')
        klass =
          case type
          when 'user'
            UserNetwork
          when 'socket'
            SocketNetwork
          when 'bridge'
            BridgeNetwork
          else
            raise ArgumentError, "unknown network type #{type.inspect}"
          end

        klass.new(i, cfg)
      end

      # @return [Integer]
      attr_reader :index

      # @return [String]
      attr_reader :type

      def initialize(i, cfg)
        @index = i
        @type = cfg.fetch('type')
        @opts = cfg.fetch('opts', {
          'network' => '10.0.2.0/24',
          'host' => '10.0.2.2',
          'dns' => '10.0.2.3'
        })
      end

      def qemu_options
        raise NotImplementedError
      end
    end

    class UserNetwork < Network
      def qemu_options
        net_opts = "net=#{@opts.fetch('network')},host=#{@opts.fetch('host')},dns=#{@opts.fetch('dns')}"
        net_opts << ",hostfwd=#{@opts['hostForward']}" if @opts['hostForward']

        [
          '-device', "virtio-net,netdev=net#{index}",
          '-netdev', "user,id=net#{index},#{net_opts}"
        ]
      end
    end

    class SocketNetwork < Network
      # @return [String]
      attr_reader :mcast_address

      # @return [Integer]
      attr_reader :mcast_port

      def initialize(_i, cfg)
        super

        mcast = cfg.fetch('mcast', {})

        @mcast_address = mcast.fetch('address', '230.0.0.1')

        mcast_port = mcast.fetch('port', 'net1')

        @mcast_port =
          case mcast_port
          when String
            PortReservation.get_port(key: "mcast:#{mcast_port}")
          when Integer
            mcast_port
          else
            raise "Invalid mcast port value #{mcast_port.inspect} (expected string or a number)"
          end
      end

      def qemu_options
        [
          '-device', "virtio-net,netdev=net#{index}",
          '-netdev', "socket,id=net#{index},mcast=#{mcast_address}:#{mcast_port}"
        ]
      end
    end

    class BridgeNetwork < Network
      # @return [String]
      attr_reader :link

      # @return [String]
      attr_reader :mac

      def initialize(_i, cfg)
        super
        @link = @opts.fetch('link')
        @mac = @opts['mac'] || gen_mac_address
      end

      def qemu_options
        [
          '-device', "virtio-net,netdev=net#{index},mac=#{@mac}",
          '-netdev', "bridge,id=net#{index},br=#{link}"
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
      cfg = JSON.parse(File.read(path))
      from_config(cfg)
    end

    # Build machine config from hash
    # @param cfg [Hash]
    # @return [MachineConfig]
    def self.from_config(cfg)
      spin = cfg.fetch('spin', 'vpsadminos')

      case spin
      when 'vpsadminos'
        VpsadminosMachineConfig.new(cfg)
      when 'nixos'
        NixosMachineConfig.new(cfg)
      else
        raise ArgumentError, "Unknown machine spin #{spin.inspect}"
      end
    end

    # @return [String]
    attr_reader :spin

    # @return [String] path to qemu package
    attr_reader :qemu

    # @return [Array<String>]
    attr_reader :extra_qemu_options

    # @return [String] path to virtiofsd package
    attr_reader :virtiofsd

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

    # @return [Array<Network>]
    attr_reader :networks

    # @param cfg [Hash]
    def initialize(cfg)
      @spin = cfg.fetch('spin', 'vpsadminos')
      @qemu = cfg.fetch('qemu')
      @extra_qemu_options = cfg.fetch('extraQemuOptions', [])
      @virtiofsd = cfg.fetch('virtiofsd')
      @kernel = cfg.fetch('kernel')
      @initrd = cfg.fetch('initrd')
      @kernel_params = cfg.fetch('kernelParams')
      @toplevel = cfg.fetch('toplevel')
      @disks = cfg.fetch('disks', []).map { |disk_cfg| Disk.new(disk_cfg) }
      @memory = cfg.fetch('memory')
      @cpus = cfg.fetch('cpus')
      @cpu = Cpu.new(cfg.fetch('cpu'))
      @shared_filesystems = cfg.fetch('sharedFileSystems', {})
      @networks = cfg.fetch('networks', [{ 'type' => 'user' }]).each_with_index.map do |net_cfg, i|
        Network.from_config(i, net_cfg)
      end
    end
  end

  class VpsadminosMachineConfig < MachineConfig
    # @return [String] path to squashfs rootfs image
    attr_reader :squashfs

    # @param cfg [Hash]
    def initialize(cfg)
      @squashfs = cfg.fetch('squashfs')
      super
    end
  end

  class NixosMachineConfig < MachineConfig
    # @return [String] path to disk image containing the root filesystem
    attr_reader :disk_image

    # @param cfg [Hash]
    def initialize(cfg)
      @disk_image = cfg.fetch('diskImage')
      super
    end
  end
end
