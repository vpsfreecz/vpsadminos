require 'osctld/lockable'

module OsCtld
  # Manages a list of interfaces
  class NetInterface::Manager
    include Lockable

    # Load interfaces from config
    # @param ct [Container]
    # @param cfg [Array]
    def self.load(ct, cfg, discover_host_links: true)
      NetInterface.sync_host_link_registry do
        entries = cfg.each_with_index.map do |v, i|
          netif = NetInterface.for(v['type'].to_sym).new(ct, i)
          netif.load(v)
          netif.setup(discover_host_links:)
          netif
        end

        NetInterface.validate_container_host_link_claims!(
          ct,
          owner_netifs: entries
        )

        new(ct, entries:)
      end
    end

    # @param ct [Container]
    def initialize(ct, entries: [])
      init_lock

      @ct = ct
      @netifs = entries
    end

    # @param netif [NetInterface::Base]
    def <<(netif)
      add(netif)
    end

    # @param netif [NetInterface::Base]
    def add(netif)
      NetInterface.sync_host_link_registry do
        NetInterface.validate_host_link_owner!(
          owner_ct: ct,
          owner_netif: netif
        )
        exclusively { netifs << netif }
        ct.save_config

        Eventd.report(
          :ct_netif,
          action: :add,
          pool: ct.pool.name,
          id: ct.id,
          name: netif.name
        )
      end
    end

    # @param netif [NetInterface::Base]
    def delete(netif)
      NetInterface.sync_host_link_registry do
        if netif.respond_to?(:host_link_identity) &&
           netif.host_link_identity.any?
          raise NetInterface::HostLinkClaimError,
                "network interface #{netif.name.inspect} still owns a host link; " \
                'complete lifecycle cleanup before removing it'
        end

        exclusively { netifs.delete(netif) }
        ct.save_config

        Eventd.report(
          :ct_netif,
          action: :remove,
          pool: ct.pool.name,
          id: ct.id,
          name: netif.name
        )
      end
    end

    def take_down
      NetInterface.sync_host_link_registry do
        get.each do |n|
          n.down if n.is_created?
        end
      end
    end

    def recovery_tainted?
      inclusively do
        netifs.any? do |netif|
          netif.respond_to?(:host_link_tainted?) && netif.host_link_tainted?
        end
      end
    end

    def setup_state_changed?
      inclusively do
        netifs.any? do |netif|
          netif.respond_to?(:setup_state_changed?) && netif.setup_state_changed?
        end
      end
    end

    # @param name [String]
    def contains?(name)
      inclusively { !(netifs.detect { |n| n.name == name }).nil? }
    end

    # @param name [String]
    def [](name)
      inclusively { netifs.detect { |n| n.name == name } }
    end

    # @return [Array<NetInterface::Base>]
    def get
      inclusively { netifs.clone }
    end

    def each(&)
      get.each(&)
    end

    include Enumerable

    # Dump interfaces to config
    def dump
      inclusively { netifs.map(&:save) }
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret.instance_variable_set('@netifs', netifs.map { |n| n.dup(new_ct) })
      ret
    end

    protected

    attr_reader :ct, :netifs
  end
end
