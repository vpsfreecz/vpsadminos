require 'fileutils'

module OsCtld
  class DistConfig::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def self.distribution(n = nil)
      if n
        DistConfig.register(n, self)

      else
        n
      end
    end

    attr_reader :ct, :distribution, :version

    def initialize(ct)
      @ct = ct
      @distribution = ct.distribution
      @version = ct.version
    end

    # Create device nodes in the container's /dev
    def create_devnodes(_opts)
      devfs = File.join(ct.rootfs, 'dev')
      Dir.mkdir(devfs) unless Dir.exist?(devfs)

      ct.devices.each do |dev|
        create_devnode(dev) if dev.name
      end
    end

    # Create a device node in the container's /dev for a specific device
    # @param device [Devices::Device]
    def create_devnode(device)
      devname = File.join(ct.rootfs, device.name)
      return if File.exist?(devname)

      devdir = File.dirname(devname)
      FileUtils.mkdir_p(devdir) unless Dir.exist?(devdir)
      syscmd("mknod #{devname} #{device.type_s} #{device.major} #{device.minor}")
    end

    # @param opts [Hash] options
    # @option opts [String] original previous hostname
    def set_hostname(opts)
      raise NotImplementedError
    end

    def network(_opts)
      raise NotImplementedError
    end

    def dns_resolvers(_opts)
      path = File.join(ct.rootfs, 'etc', 'resolv.conf')

      File.open("#{path}.new", 'w') do |f|
        ct.dns_resolvers.each { |v| f.puts("nameserver #{v}") }
      end

      File.rename("#{path}.new", path)
    end

    # @param opts [Hash] options
    # @option opts [String] user
    # @option opts [String] password
    def passwd(opts)
      ret = ct_syscmd(
        ct,
        'chpasswd',
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        valid_rcs: :all
      )

      return true if ret[:exitstatus] == 0
      log(:warn, ct, "Unable to set password: #{ret[:output]}")
    end
  end
end
