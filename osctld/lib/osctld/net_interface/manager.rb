require 'osctld/lockable'

module OsCtld
  # Manages a list of interfaces
  class NetInterface::Manager
    include Lockable

    # Load interfaces from config
    # @param ct [Container]
    # @param cfg [Array]
    def self.load(ct, cfg)
      new(
        ct,
        entries: cfg.each_with_index.map do |v, i|
          netif = NetInterface.for(v['type'].to_sym).new(ct, i)
          netif.load(v)
          netif.setup
          netif
        end
      )
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

    # @param netif [NetInterface::Base]
    def delete(netif)
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

    def take_down
      inclusively do
        netifs.each do |n|
          n.down if n.is_up?
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
