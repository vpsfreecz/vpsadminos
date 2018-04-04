require 'fileutils'

module OsCtld
  module Lxc
    CONFIGS = '/run/osctl/configs/lxc'

    def self.dist_name(dist)
      case dist
      when 'suse'
        'opensuse'

      else
        dist
      end
    end

    def self.dist_lxc_configs(dist, ver)
      name = dist_name(dist)

      [
        File.join(CONFIGS, 'common.conf'),
        File.join(CONFIGS, name, 'common.conf'),
        File.join(CONFIGS, name, "#{ver}.conf"),
      ].select { |cfg| File.exist?(cfg) }
    end

    def self.install_lxc_configs(dst)
      pid = Process.fork do
        abs_root = File.absolute_path(OsCtld.root)
        cfg_root = File.join(abs_root, 'configs', 'lxc')

        Dir.chdir(cfg_root)

        Dir.glob('**/*.conf').each do |cfg|
          link_path = File.join(dst, cfg)

          if File.symlink?(link_path) || File.exist?(link_path)
            File.unlink(link_path)
          end

          dir = File.join(dst, File.dirname(cfg))
          FileUtils.mkpath(dir)

          File.symlink(File.join(cfg_root, cfg), link_path)
        end
      end

      Process.wait(pid)
      fail 'unable to install lxc configs' if $?.exitstatus != 0
    end
  end
end
