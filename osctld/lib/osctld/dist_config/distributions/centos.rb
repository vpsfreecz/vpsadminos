require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::CentOS < DistConfig::Distributions::RedHat
    distribution :centos

    class Configurator < DistConfig::Distributions::RedHat::Configurator
      protected

      def network_class
        [
          DistConfig::Network::RedHatNetworkManager,
          DistConfig::Network::RedHatInitScripts
        ]
      end
    end
  end
end
