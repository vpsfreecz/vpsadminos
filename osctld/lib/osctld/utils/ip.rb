module OsCtld
  module Utils::Ip
    # @return [OsCtl::Lib::SystemCommandResult]
    def ip(ip_v, args, opts = {})
      cmd = ['ip']

      case ip_v
      when 4
        cmd << '-4'
      when 6
        cmd << '-6'
      when :all
      else
        fail "unknown IP version '#{ip_v}'"
      end

      cmd.concat(args)
      syscmd(cmd.join(' '), opts)
    end
  end
end
