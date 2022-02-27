require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::Fedora < DistConfig::Distributions::RedHat
    distribution :fedora

    class Configurator < DistConfig::Distributions::RedHat::Configurator
      protected
      def network_class
        if version.to_i >= 30
          DistConfig::Network::RedHatNetworkManager
        else
          DistConfig::Network::RedHatInitScripts
        end
      end
    end
  end
end
