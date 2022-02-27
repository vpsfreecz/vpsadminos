require 'forwardable'
require 'osctld/dist_config/helpers/common'

module OsCtld
  class DistConfig::Network::Base
    extend Forwardable

    include OsCtl::Lib::Utils::File
    include DistConfig::Helpers::Common

    # @param configurator [DistConfig::Configurator]
    def initialize(configurator)
      @configurator = configurator
    end

    # Return true if this class can be used to configure the network
    # @return [Boolean]
    def usable?
      false
    end

    # @param netifs [Array<NetInterface::Base>]
    def configure(netifs)
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

    protected
    attr_reader :configurator

    def_delegators :configurator, :ctid, :rootfs, :distribution, :version
  end
end
