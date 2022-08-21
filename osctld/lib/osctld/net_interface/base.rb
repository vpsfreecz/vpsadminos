module OsCtld
  class NetInterface::Base
    def self.type(name = nil)
      if name
        NetInterface.register(name, self)
        @type = name

      else
        @type
      end
    end

    def self.setup

    end

    include Lockable

    attr_reader :name, :index, :hwaddr, :max_tx, :max_rx

    def initialize(ct, index)
      @ct = ct
      @index = index
      init_lock
    end

    def type
      self.class.type
    end

    # Setup a new interface
    # @param opts [Hash] options, different per interface type, symbol keys
    def create(opts)
      @name = opts[:name]
      @hwaddr = opts[:hwaddr]
      @max_tx = opts.fetch(:max_tx, 0)
      @max_rx = opts.fetch(:max_rx, 0)
    end

    # Load configuration
    # @param cfg [Hash] configuration options, string keys
    def load(cfg)
      @name = cfg['name']
      @hwaddr = cfg['hwaddr']
      @max_tx = cfg.fetch('max_tx', 0)
      @max_rx = cfg.fetch('max_rx', 0)
    end

    # Dump configuration
    # @return [Hash] hash with string keys, given the has that `load` has
    #   then restores the state from
    def save
      inclusively do
        {
          'type' => type.to_s,
          'name' => name,
          'hwaddr' => hwaddr,
          'max_tx' => max_tx,
          'max_rx' => max_rx,
        }
      end
    end

    # Rename the interface within the container
    # @param new_name [String]
    def rename(new_name)
      old_name = inclusively { @name }
      exclusively { @name = new_name }

      Eventd.report(
        :ct_netif,
        action: :rename,
        pool: ct.pool.name,
        id: ct.id,
        name: old_name,
        new_name: new_name,
      )
    end

    # Change interface properties
    # @param opts [Hash] options, see subclasses for more information
    # @option opts [String] :hwaddr
    # @option opts [Integer] :max_tx
    # @option opts [Integer] :max_rx
    def set(opts)
      exclusively do
        @hwaddr = opts[:hwaddr] if opts.has_key?(:hwaddr)
        @max_tx = opts[:max_tx] if opts.has_key?(:max_tx)
        @max_rx = opts[:max_rx] if opts.has_key?(:max_rx)
      end
    end

    # Initialize the interface on creation / osctld restart
    def setup

    end

    # Return variables for template generating LXC configuration for this
    # interface
    # @return [Hash]
    def render_opts
      raise NotImplementedError
    end

    # Called when the interface goes up
    def up(*_args)

    end

    # Called when the interface goes down
    def down(*_args)

    end

    # Called to check if DistConfig for network can be run
    # @return [Boolean]
    def can_run_distconfig?
      true
    end

    # List IP addresses
    # @return [Array]
    def ips(v)
      raise NotImplementedError
    end

    # @return [Boolean]
    def has_ip?(addr)
      ips(addr.ipv4? ? 4 : 6).detect { |v| v == addr } ? true : false
    end

    def can_add_ip?(addr)
      true
    end

    # Add IP address to this interface
    # @param addr [IPAddress]
    def add_ip(addr)
      raise NotImplementedError
    end

    # Delete IP address from this interface
    # @param addr [IPAddress]
    def del_ip(addr)
      raise NotImplementedError
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected
    attr_reader :ct
  end
end
