require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Rocky < DistConfig::RedHat
    distribution :rocky

    class Configurator < DistConfig::RedHat::Configurator
      protected
      def network_class
        DistConfig::Network::RedHatNetworkManager
      end
    end
  end
end
