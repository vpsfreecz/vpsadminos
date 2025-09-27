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

      cgroup_v2_only = cgroup_v2_only_distro?(config['distribution'], config['version'])

      if config['init_cmd'].include?(systemd_opt_force_v1)
        if cgroup_v2_only
          log(:info, "Removing option #{systemd_opt_force_v1} from init command")
          config['init_cmd'].delete(systemd_opt_force_v1)
        end
      elsif !cgroup_v2_only
        log(:info, "Adding option #{systemd_opt_force_v1} to init command")
        config['init_cmd'] << systemd_opt_force_v1
      end

      if config['init_cmd'].include?(systemd_opt_force_v2)
        unless cgroup_v2_only
          log(:info, "Removing option #{systemd_opt_force_v2} from init command")
          config['init_cmd'].delete(systemd_opt_force_v2)
        end
      elsif cgroup_v2_only
        log(:info, "Adding option #{systemd_opt_force_v2} to init command")
        config['init_cmd'] << systemd_opt_force_v2
      end
    end

    def to_cgroup_v2
      if systemd_distros.include?(config['distribution']) \
         && config['init_cmd'] \
         && config['init_cmd'].include?(systemd_opt_force_v1)
        log(:info, "Removing option #{systemd_opt_force_v1} from init command")
        config['init_cmd'].delete(systemd_opt_force_v1)
      end

      if systemd_distros.include?(config['distribution']) \
         && config['init_cmd'] \
         && config['init_cmd'].include?(systemd_opt_force_v2)
        log(:info, "Removing option #{systemd_opt_force_v2} from init command")
        config['init_cmd'].delete(systemd_opt_force_v2)
      end
    end

    def systemd_opt_force_v1
      'systemd.unified_cgroup_hierarchy=0'
    end

    def systemd_opt_force_v2
      'systemd.unified_cgroup_hierarchy=1'
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
