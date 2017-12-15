module OsCtld
  class DistConfig::Unsupported < DistConfig::Base
    distribution :unsupported

    include Utils::Log

    def network(opts)
      log(:warn, "CT #{ct.id}", "Unable to configure network: #{ct.distribution} not supported")
    end
  end
end
