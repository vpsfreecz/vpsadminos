require 'osctld/dist_config/distributions/debian'

module OsCtld
  class DistConfig::Distributions::Devuan < DistConfig::Distributions::Debian
    distribution :devuan
  end
end
