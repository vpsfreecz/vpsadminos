require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::AlmaLinux < DistConfig::RedHat
    distribution :almalinux

    protected
    def config_backend
      :network_manager
    end
  end
end
