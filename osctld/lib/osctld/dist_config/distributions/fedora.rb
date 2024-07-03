require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::Fedora < DistConfig::Distributions::RedHat
    distribution :fedora

    class Configurator < DistConfig::Distributions::RedHat::Configurator
      protected

      def network_class
        [
          DistConfig::Network::NetworkManager,
          DistConfig::Network::RedHatNetworkManager,
          DistConfig::Network::SystemdNetworkd,
          DistConfig::Network::RedHatInitScripts
        ]
      end
    end
  end
end
