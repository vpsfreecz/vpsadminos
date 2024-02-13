require 'libosctl'
require 'osctld/dist_config/helpers/common'

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
    include DistConfig::Helpers::Common

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
      @network_backend = instantiate_network_class
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def set_hostname(new_hostname, old_hostname: nil)
      raise NotImplementedError
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def update_etc_hosts(new_hostname, old_hostname: nil)
      path = File.join(rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)

      if old_hostname
        hosts.replace(old_hostname, new_hostname)
      else
        hosts.set(new_hostname)
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
      network_backend && network_backend.configure(netifs)
    end

    # Called when a new network interface is added to a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def add_netif(netifs, netif)
      network_backend && network_backend.add_netif(netifs, netif)
    end

    # Called when a network interface is removed from a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def remove_netif(netifs, netif)
      network_backend && network_backend.remove_netif(netifs, netif)
    end

    # Called when an existing network interface is renamed
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    # @param old_name [String]
    def rename_netif(netifs, netif, old_name)
      network_backend && network_backend.rename_netif(netifs, netif, old_name)
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

    # @return [DistConfig::Network::Base, nil]
    attr_reader :network_backend

    # Return a class which is used for network configuration
    #
    # The class should be a subclass of {DistConfig::Network::Base}.
    #
    # If an array of classes is returned, they are instantiated and the first
    # class for which {DistConfig::Network::Base#usable?} returns true is used.
    # An exception is raised if no class is found to be usable.
    #
    # If `nil` is returned, you are expected to implement {#network} and other
    # methods for network configuration yourself.
    #
    # @return [Class, Array<Class>, nil]
    def network_class
      raise NotImplementedError
    end

    # @return [DistConfig::Network::Base, nil]
    def instantiate_network_class
      klass = network_class

      if klass.nil?
        log(:debug, 'Using distribution-specific network configuration')
        nil

      elsif klass.is_a?(Array)
        klass.each do |k|
          inst = k.new(self)

          if inst.usable?
            log(:debug, "Using #{k} for network configuration")
            return inst
          end
        end

        log(:warn, "No network class usable for #{self.class}")
        nil

      else
        log(:debug, "Using #{network_class} for network configuration")
        network_class.new(self)
      end
    end
  end
end
