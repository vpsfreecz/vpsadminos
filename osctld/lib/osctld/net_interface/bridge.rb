require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Bridge < NetInterface::Veth
    type :bridge

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :link, :dhcp

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] link
    # @option opts [Boolean] dhcp
    def create(opts)
      super

      @link = opts[:link]
      @dhcp = opts.has_key?(:dhcp) ? opts[:dhcp] : true
      @gateway = {}
    end

    def load(cfg)
      super

      @link = cfg['link']
      @dhcp = cfg.has_key?('dhcp') ? cfg['dhcp'] : true
      @gateway = {}
    end

    def save
      super.merge({
        'link' => link,
        'dhcp' => dhcp,
      })
    end

    # @param opts [Hash] options
    # @option opts [String] :link
    # @option opts [Boolean] :dhcp
    def set(opts)
      super
      @link = opts[:link] if opts[:link]
      @dhcp = opts[:dhcp] if opts.has_key?(:dhcp)
    end

    def render_opts
      super.merge({
        link: link,
      })
    end

    def add_ip(addr)
      super

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        # Add IP within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr add #{addr.to_string} dev #{name}",
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
          "ip -#{v} addr del #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    # @param v [Integer] IP version
    # @return [String, nil]
    def gateway(v)
      return @gateway[v] if @gateway.has_key?(v)

      ifaddr = Socket.getifaddrs.detect do |ifaddr|
        ifaddr.name == link && ifaddr.addr.ip? && ifaddr.addr.send(:"ipv#{v}?")
      end

      @gateway[v] = ifaddr ? ifaddr.addr.ip_address : nil
    end
  end
end
