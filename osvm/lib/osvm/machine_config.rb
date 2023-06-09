require 'json'

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
    end
  end
end
