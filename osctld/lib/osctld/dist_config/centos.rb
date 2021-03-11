require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::CentOS < DistConfig::RedHat
    distribution :centos

    protected
    def config_backend
      if version.to_i >= 8
        :network_manager
      else
        :initscripts
      end
    end
  end
end
