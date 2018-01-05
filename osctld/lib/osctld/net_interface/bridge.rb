module OsCtld
  class NetInterface::Bridge < NetInterface::Base
    type :bridge

    include Utils::Log
    include Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :link

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] link
    def create(opts)
      super
      @link = opts[:link]
      @ips = {4 => [], 6 => []}
    end

    def load(cfg)
      super
      @link = cfg['link']

      if cfg['ip_addresses']
        @ips = Hash[ cfg['ip_addresses'].map do |v, ips|
          [v, ips.map { |ip| IPAddress.parse(ip) }]
        end]

      else
        @ips = {4 => [], 6 => []}
      end
    end

    def save
      ret = super
      ret.update({
        'link' => link,
        'ip_addresses' => Hash[@ips.map { |v, ips| [v, ips.map(&:to_string)] }],
      })
      ret
    end

    def render_opts
      {
        name: name,
        index: index,
        hwaddr: hwaddr,
        link: link,
        ips: @ips,
      }
    end

    def ips(v)
      @ips[v].clone
    end

    def add_ip(addr)
      v = addr.ipv4? ? 4 : 6
      @ips[v] << addr

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
      v = addr.ipv4? ? 4 : 6
      @ips[v].delete_if { |v| v == addr }

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
