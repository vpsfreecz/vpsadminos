require 'osctld/dist_config/distributions/redhat'

module OsCtld
  class DistConfig::Distributions::CentOS < DistConfig::Distributions::RedHat
    distribution :centos

    class Configurator < DistConfig::Distributions::RedHat::Configurator
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
