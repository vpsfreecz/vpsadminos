require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Rocky < DistConfig::RedHat
    distribution :rocky

    protected
    def config_backend
      :network_manager
    end
  end
end
