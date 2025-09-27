require 'osctld/container/adaptors/base'

module OsCtld
  class Container::Adaptor::CGroup < Container::Adaptor::Base
    register :cgroup

    def adapt
      send(:"to_cgroup_v#{CGroup.version}")
      config
    end

    protected

    def to_cgroup_v1
      return unless systemd_distros.include?(config['distribution'])

      config['init_cmd'] ||= ['/sbin/init']

      if config['init_cmd'].include?(systemd_opt)
        if cgroup_v2_only_distro?(config['distribution'], config['version'])
          log(:info, "Removing option #{systemd_opt} from init command")
          config['init_cmd'].delete(systemd_opt)
        end

        return
      end

      log(:info, "Adding option #{systemd_opt} to init command")
      config['init_cmd'] << systemd_opt
    end

    def to_cgroup_v2
      if systemd_distros.include?(config['distribution']) \
         && config['init_cmd'] \
         && config['init_cmd'].include?(systemd_opt)
        log(:info, "Removing option #{systemd_opt} from init command")
        config['init_cmd'].delete(systemd_opt)
      end
    end

    def systemd_opt
      'systemd.unified_cgroup_hierarchy=0'
    end

    def systemd_distros
      %w[almalinux arch centos debian fedora gentoo opensuse rocky ubuntu]
    end

    def cgroup_v2_only_distro?(distribution, version)
      distribution == 'arch' \
        || (distribution == 'debian' && (version.start_with?('testing-') || version.start_with?('unstable-')))
    end
  end
end
