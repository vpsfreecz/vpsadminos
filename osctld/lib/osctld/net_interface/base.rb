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

    attr_reader :name, :index

    def initialize(ct, index)
      @ct = ct
      @index = index
    end

    def type
      self.class.type
    end

    # Setup a new interface
    # @param opts [Hash] options, different per interface type, symbol keys
    def create(opts)
      @name = opts[:name]
    end

    # Load configuration
    # @param cfg [Hash] configuration options, string keys
    def load(cfg)
      @name = cfg['name']
    end

    # Dump configuration
    # @return [Hash] hash with string keys, given the has that `load` has
    #   then restores the state from
    def save
      {'type' => type.to_s, 'name' => name}
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

    # List IP addresses
    # @return [Array]
    def ips(v)
      raise NotImplementedError
    end

    # @return [Boolean]
    def has_ip?(addr)
      s = addr.to_string
      ips(addr.ipv4? ? 4 : 6).detect { |v| v == s } ? true : false
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

    protected
    attr_reader :ct
  end
end
