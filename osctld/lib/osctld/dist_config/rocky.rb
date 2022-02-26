require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Rocky < DistConfig::RedHat
    distribution :rocky

    class Configurator < DistConfig::RedHat::Configurator
      protected
      def config_backend
        :network_manager
      end
    end
  end
end
