module OsCtld
  class NetInterface::Bridge < NetInterface::Veth
    type :bridge

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :link

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] link
    def create(opts)
      super

      @link = opts[:link]
    end

    def load(cfg)
      super

      @link = cfg['link']
    end

    def save
      super.merge({
        'link' => link,
      })
    end

    def render_opts
      super.merge({
        link: link,
        ips: @ips,
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
  end
end
