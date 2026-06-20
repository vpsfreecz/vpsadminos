require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Bridge < NetInterface::Veth
    type :bridge

    AUTO_GATEWAY_WAIT_TIMEOUT = 10
    AUTO_GATEWAY_WAIT_INTERVAL = 0.1

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
      @gateways = normalize_gateways(opts[:gateways], default: { 4 => 'auto', 6 => 'auto' })
    end

    def load(cfg)
      super

      @link = cfg['link']
      @dhcp = cfg.has_key?('dhcp') ? cfg['dhcp'] : true

      @gateways = normalize_gateways(cfg['gateways'], default: { 4 => 'auto', 6 => 'auto' })
    end

    def save
      inclusively do
        super.merge({
          'link' => link,
          'dhcp' => dhcp,
          'gateways' => gateways.any? ? gateways.transform_keys { |k| "v#{k}" } : nil
        })
      end
    end

    # @param opts [Hash] options
    # @option opts [String] :link
    # @option opts [Boolean] :dhcp
    # @option opts [Hash<Integer, String>] :gateways
    def set(opts)
      NetInterface.sync_host_link_registry do
        super

        exclusively do
          @link = opts[:link] if opts[:link]
          @dhcp = opts[:dhcp] if opts.has_key?(:dhcp)

          if opts[:gateways]
            @gateways.update(normalize_gateways(opts[:gateways], default: {}))
          end
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
    # @param wait [Boolean] wait briefly for auto gateway resolution
    # @return [Boolean]
    def has_gateway?(v, wait: false)
      !gateway_or_nil(v, wait:).nil?
    end

    # @param v [Integer] IP version
    # @param wait [Boolean] wait briefly for auto gateway resolution
    # @return [String, nil]
    def gateway_or_nil(v, wait: false)
      get_gateway(v, wait:)
    end

    # @param v [Integer] IP version
    # @param wait [Boolean] wait briefly for auto gateway resolution
    # @return [String]
    def gateway(v, wait: false)
      get_gateway(v, wait:) || (raise 'no gateway set')
    end

    def dup(new_ct)
      ret = super
      ret.instance_variable_set('@gateways', gateways.dup)
      ret
    end

    protected

    def normalize_gateways(gateways, default:)
      return default unless gateways

      [4, 6].each_with_object({}) do |ip_v, ret|
        value = gateways[ip_v] || gateways[ip_v.to_s] || gateways["v#{ip_v}"]
        ret[ip_v] = value unless value.nil?
      end
    end

    def get_gateway(v, wait: false)
      inclusively do
        case gateways[v]
        when nil, 'auto'
          wait ? wait_for_auto_gateway(v) : detect_auto_gateway(v)

        when 'none'
          nil

        else
          gateways[v]
        end
      end
    end

    def wait_for_auto_gateway(v)
      deadline = Time.now + AUTO_GATEWAY_WAIT_TIMEOUT

      loop do
        gateway = detect_auto_gateway(v)
        return gateway if gateway || Time.now >= deadline

        sleep(AUTO_GATEWAY_WAIT_INTERVAL)
      end
    end

    def detect_auto_gateway(v)
      any_ifaddr = Socket.getifaddrs.detect do |ifaddr|
        ifaddr.name == link && ifaddr.addr.ip? && ifaddr.addr.send(:"ipv#{v}?")
      end

      any_ifaddr ? any_ifaddr.addr.ip_address : nil
    end
  end
end
