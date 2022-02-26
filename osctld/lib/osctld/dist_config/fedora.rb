require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Fedora < DistConfig::RedHat
    distribution :fedora

    class Configurator < DistConfig::RedHat::Configurator
      protected
      def config_backend
        if version.to_i >= 30
          :network_manager
        else
          :initscripts
        end
      end
    end
  end
end
