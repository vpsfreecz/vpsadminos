require 'osctld/dist_config/distributions/debian'

module OsCtld
  class DistConfig::Distributions::Alpine < DistConfig::Distributions::Debian
    distribution :alpine
  end
end
