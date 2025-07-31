require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::Rocky < DistConfig::Distributions::RedHat
    distribution :rocky

    class Configurator < DistConfig::Distributions::RedHat::Configurator
      protected

      def network_class
        [
          DistConfig::Network::NetworkManager,
          DistConfig::Network::RedHatNetworkManager,
          DistConfig::Network::RedHatInitScripts
        ]
      end
    end
  end
end
