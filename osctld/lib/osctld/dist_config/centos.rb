require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::CentOS < DistConfig::RedHat
    distribution :centos

    class Configurator < DistConfig::RedHat::Configurator
      protected
      def network_class
        if version.start_with?('stream-') \
           || version == 'latest-stream' \
           || version.to_i >= 8
          DistConfig::Network::RedHatNetworkManager
        else
          DistConfig::Network::RedHatInitScripts
        end
      end
    end
  end
end
