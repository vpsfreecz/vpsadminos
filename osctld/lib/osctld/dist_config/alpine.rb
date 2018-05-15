require 'osctld/dist_config/debian'

module OsCtld
  class DistConfig::Alpine < DistConfig::Debian
    distribution :alpine
  end
end
