require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::CentOS < DistConfig::RedHat
    distribution :centos
  end
end
