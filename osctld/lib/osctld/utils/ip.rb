module OsCtld
  module Utils::Ip
    def ip(ip_v, *args)
      cmd = ['ip']
      cmd << '-6' if ip_v == 6
      cmd.concat(args)
      syscmd(cmd.join(' '))
    end
  end
end
