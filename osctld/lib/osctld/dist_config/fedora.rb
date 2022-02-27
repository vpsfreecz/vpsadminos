require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Fedora < DistConfig::RedHat
    distribution :fedora

    class Configurator < DistConfig::RedHat::Configurator
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
