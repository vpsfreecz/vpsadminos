module OsCtld
  module Lxc
    CONFIGS = '/etc/lxc/config'

    def self.dist_name(dist)
      case dist
      when 'arch'
        'archlinux'

      when 'suse'
        'opensuse'

      when 'void'
        'voidlinux'

      else
        dist
      end
    end

    def self.dist_lxc_configs(dist)
      name = dist_name(dist)

      ret = [
        File.join(CONFIGS, "#{name}.common.conf"),
        File.join(CONFIGS, "#{name}.userns.conf"),
      ].select { |cfg| File.exist?(cfg) }

      ret << File.join(CONFIGS, 'userns.conf') if ret.empty?
      ret
    end
  end
end
