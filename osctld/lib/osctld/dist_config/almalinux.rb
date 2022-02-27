require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::AlmaLinux < DistConfig::RedHat
    distribution :almalinux

    class Configurator < DistConfig::RedHat::Configurator
      protected
      def network_class
        DistConfig::Network::RedHatNetworkManager
      end
    end
  end
end
