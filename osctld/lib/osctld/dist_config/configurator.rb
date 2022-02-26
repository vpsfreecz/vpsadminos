require 'libosctl'

module OsCtld
  # Base class for per-distribution configurators
  #
  # Configurators are used to manipulate the container's root filesystem. It is
  # called from a forked process with a container-specific mount namespace, but
  # retaining access to all osctld memory.
  class DistConfig::Configurator
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :ctid

    # @return [String]
    attr_reader :rootfs

    # @return [String]
    attr_reader :distribution

    # @return [String]
    attr_reader :version

    # @param ctid [String]
    # @param rootfs [String]
    # @param distribution [String]
    # @param version [String]
    def initialize(ctid, rootfs, distribution, version)
      @ctid = ctid
      @rootfs = rootfs
      @distribution = distribution
      @version = version
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def set_hostname(new_hostname, old_hostname: nil)
      raise NotImplementedError
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def update_etc_hosts(hostname, old_hostname: nil)
      path = File.join(rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)

      if old_hostname
        hosts.replace(old_hostname, hostname)
      else
        hosts.set(hostname)
      end
    end

    def unset_etc_hosts
      path = File.join(rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)
      hosts.unmanage
    end

    # Configure networking
    # @param netifs [Array<NetInterface::Base>]
    def network(netifs)
      raise NotImplementedError
    end

    # Called when a new network interface is added to a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def add_netif(netifs, netif)

    end

    # Called when a network interface is removed from a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def remove_netif(netifs, netif)

    end

    # Called when an existing network interface is renamed
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    # @param old_name [String]
    def rename_netif(netifs, netif, old_name)

    end

    # Configure DNS resolvers
    # @param resolvers [Array<String>]
    def dns_resolvers(resolvers)
      writable?(File.join(rootfs, 'etc', 'resolv.conf')) do |path|
        File.open("#{path}.new", 'w') do |f|
          resolvers.each { |v| f.puts("nameserver #{v}") }
        end

        File.rename("#{path}.new", path)
      end
    end

    def log_type
      ctid
    end

    protected
    # Check if the file at `path` si writable by its user
    #
    # If the file doesn't exist, we take it as writable. If a block is given,
    # it is called if `path` is writable.
    #
    # @yieldparam path [String]
    def writable?(path)
      begin
        return if (File.stat(path).mode & 0200) != 0200
      rescue Errno::ENOENT
        # pass
      end

      yield(path) if block_given?
      true
    end
  end
end
