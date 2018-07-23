require 'osctld/dist_config/debian'

module OsCtld
  class DistConfig::Devuan < DistConfig::Debian
    distribution :devuan
  end
end
