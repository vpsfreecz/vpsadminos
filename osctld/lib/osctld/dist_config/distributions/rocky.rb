require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::Rocky < DistConfig::Distributions::RedHat
    distribution :rocky

    class Configurator < DistConfig::Distributions::RedHat::Configurator
      protected

      def network_class
        DistConfig::Network::RedHatNetworkManager
      end
    end
  end
end
