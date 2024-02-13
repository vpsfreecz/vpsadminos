require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Bridge < NetInterface::Veth
    type :bridge

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :link, :dhcp, :gateways

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] link
    # @option opts [Boolean] dhcp
    # @option opts [Hash] gateways
    def create(opts)
      super

      @link = opts[:link]
      @dhcp = opts.has_key?(:dhcp) ? opts[:dhcp] : true
      @gateways = opts[:gateways] || { 4 => 'auto', 6 => 'auto' }
    end

    def load(cfg)
      super

      @link = cfg['link']
      @dhcp = cfg.has_key?('dhcp') ? cfg['dhcp'] : true

      @gateways = if cfg['gateways']
                    Hash[ [4, 6].map do |ip_v|
                      [ip_v, cfg['gateways']["v#{ip_v}"] || 'auto']
                    end]
                  else
                    { 4 => 'auto', 6 => 'auto' }
                  end
    end

    def save
      inclusively do
        super.merge({
          'link' => link,
          'dhcp' => dhcp,
          'gateways' => gateways.any? ? Hash[gateways.map { |k, v| ["v#{k}", v] }] : nil
        })
      end
    end

    # @param opts [Hash] options
    # @option opts [String] :link
    # @option opts [Boolean] :dhcp
    # @option opts [Hash<Integer, String>] :gateways
    def set(opts)
      exclusively do
        super
        @link = opts[:link] if opts[:link]
        @dhcp = opts[:dhcp] if opts.has_key?(:dhcp)

        if opts[:gateways]
          @gateways.update(opts[:gateways])
          @gateway_cache = nil
        end
      end
    end

    def render_opts
      inclusively do
        super.merge({
          link:
        })
      end
    end

    def add_ip(addr)
      super

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        # Add IP within the CT
        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'addr', 'add', addr.to_string, 'dev', name],
          valid_rcs: [2]
        )
      end
    end

    def del_ip(addr)
      super

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        # Remove IP from within the CT
        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'addr', 'del', addr.to_string, 'dev', name],
          valid_rcs: [2]
        )
      end
    end

    # @param v [Integer] IP version
    # @return [Boolean]
    def has_gateway?(v)
      !get_gateway(v).nil?
    end

    # @param v [Integer] IP version
    # @return [String]
    def gateway(v)
      get_gateway(v) || (raise 'no gateway set')
    end

    protected

    def get_gateway(v)
      inclusively do
        @gateway_cache ||= {}
        return @gateway_cache[v] if @gateway_cache.has_key?(v)

        gw = case gateways[v]
             when nil, 'auto'
               ifaddr = Socket.getifaddrs.detect do |ifaddr|
                 ifaddr.name == link && ifaddr.addr.ip? && ifaddr.addr.send(:"ipv#{v}?")
               end

               ifaddr ? ifaddr.addr.ip_address : nil

             when 'none'
               nil

             else
               gateways[v]
             end

        @gateway_cache[v] = gw
      end
    end
  end
end
