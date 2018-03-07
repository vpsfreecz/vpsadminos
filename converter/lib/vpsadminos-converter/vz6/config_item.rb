require 'ipaddress'

module VpsAdminOS::Converter
  class Vz6::ConfigItem
    Device = Struct.new(:type, :major, :minor, :mode) do
      def to_s
        "#{type}:#{major}:#{minor}:#{mode}"
      end

      def to_ct_device
        Devices::Device.new(
          case type
          when 'b'
            'block'
          when 'c'
            'char'
          else
            fail "unsupported device type '#{type}'"
          end,
          major,
          minor,
          # q is for quota management, not supported in vpsAdminOS
          mode == 'none' ? '' : mode.gsub('q', '')
        )
      end
    end

    attr_reader :key, :value

    def initialize(ctid, k, v)
      @key = k
      @value = parse(ctid, v)
    end

    def consumed?
      @consumed.nil? ? false : @consumed
    end

    def consume
      @consumed = true
    end

    protected
    def parse(ctid, v)
      case key
      # Miscellaneous
      when 'NAME', 'DESCRIPTION', 'OSTEMPLATE', 'MOUNT_OPTS', 'ORIGIN_SAMPLE',
           'VE_LAYOUT'
        v

      when 'VE_ROOT', 'VE_PRIVATE'
        veid_subst(ctid, v)

      when 'ONBOOT', 'DISABLED'
        parse_bool(v)

      when 'BOOTORDER', 'STOP_TIMEOUT'
        parse_num(v)

      # Networking
      when 'HOSTNAME', 'NETFILTER'
        v

      when 'NAMESERVER', 'IP_ADDRESS'
        parse_addrs(v)

      when 'SEARCHDOMAIN'
        parse_list(v)

      # VSwap limits
      when 'PHYSPAGES', 'SWAPPAGES'
        parse_limit(v, pages: true)

      # CPU fair scheduler parameters
      when 'CPUUNITS', 'CPUS', 'CPULIMIT'
        parse_num(v)

      # User beancounters
      # TODO

      # Devices
      when 'DEVICES'
        parse_devices(v)

      # Capabilities & features
      when 'CAPABILITY', 'FEATURES'
        parse_onoff_list(v)

      else
        v
      end
    end

    def parse_list(v)
      v.split(/\s/).map(&:strip).delete_if(&:empty?)
    end

    def parse_bool(v)
      case v
      when 'yes'
        true
      when 'no'
        false
      else
        fail "unexpected boolean value #{key}=\"#{v}\""
      end
    end

    def parse_num(v)
      v.to_i
    end

    def veid_subst(ctid, v)
      v.gsub!(/\$VEID/, ctid)
      v.gsub!(/\$\{VEID\}/, ctid)
      v
    end

    def parse_addrs(v)
      parse_list(v).map { |addr| IPAddress.parse(addr) }
    end

    def parse_limit(v, pages: nil)
      if v.index(':')
        v.split(':')[0..1].map { |v| parse_unit(v, pages: pages) }

      else
        ret = parse_unit(v, pages: pages)
        [ret, ret]
      end
    end

    def parse_unit(v, pages: false)
      return 0 if v == 'unlimited'

      n = v.to_i
      suffix = v.strip[-1]
      return n if suffix =~ /^\d+$/

      if suffix.upcase == 'P'
        n

      elsif i = %w(B K M G T).index(suffix.upcase)
        i.times { n *= 1024 }

        if pages
          n / 4096
        else
          n
        end

      else
        fail "unsupported suffix '#{suffix}'"
      end
    end

    def parse_devices(v)
      parse_list(v).map { |dev| Device.new(*dev.split(':')) }
    end

    def parse_onoff_list(v)
      Hash[
        parse_list(v).map do |cap|
          name, enabled = cap.split(':')

          case enabled
          when 'on'
            [name.downcase, true]
          when 'off'
            [name.downcase, false]
          else
            fail "unknown mode '#{name}:#{enabled}'"
          end
        end
      ]
    end
  end
end
