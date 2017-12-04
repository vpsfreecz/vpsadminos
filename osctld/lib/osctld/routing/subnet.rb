module OsCtld
  class Routing::Subnet
    Allocation = Struct.new(:subnet, :net_addr, :host_ip, :ct_ip) do
      def release
        subnet.release(net_addr)
      end
    end

    class << self
      %i(bits split_prefix).each do |param|
        define_method(param) do |v = nil|
          if v
            instance_variable_set("@#{param}", v)

          else
            instance_variable_get("@#{param}")
          end
        end
      end
    end

    attr_reader :net_addr, :size

    def initialize(net_addr)
      @net_addr = net_addr
      @used = []

      bits = self.class.bits
      split_prefix = self.class.split_prefix

      if net_addr.prefix >= split_prefix
        raise "#{net_addr.to_string} cannot be split into /#{split_prefix} networks"
      end

      @size = (2**(bits - net_addr.prefix.to_i)) / (2**(bits - split_prefix))
    end

    def free?
      @used.size < @size
    end

    def version
      net_addr.ipv4? ? 4 : 6
    end

    def allocate
      net = find_free_net
      raise 'no free network found' unless net
      @used << net

      addr = uint_to_addr(net)
      Allocation.new(self, addr, host_ip(net), ct_ip(net))
    end

    def release(addr)
      @used.delete(addr_to_uint(addr))
    end

    protected
    def find_free_net
      each_network do |net|
        next if @used.include?(net)
        return net
      end

      nil
    end

    def host_ip(net)
      addr = uint_to_addr(net+1)
      addr.prefix = self.class.split_prefix
      addr
    end

    def ct_ip(net)
      addr = uint_to_addr(net+2)
      addr.prefix = self.class.split_prefix
      addr
    end

    def each_network
      raise NotImplementedError
    end

    def uint_to_addr
      raise NotImplementedError
    end

    def addr_to_uint
      raise NotImplementedError
    end
  end
end
