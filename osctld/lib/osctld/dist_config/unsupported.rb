module OsCtld
  class DistConfig::Unsupported < DistConfig::Base
    distribution :unsupported

    include OsCtl::Lib::Utils::Log

    def set_hostname(opts)
      log(
        :warn,
        ct,
        "Unable to set hostname: #{ct.distribution} not supported"
      )
    end

    def network(opts)
      log(
        :warn,
        ct,
        "Unable to configure network: #{ct.distribution} not supported"
      )
    end
  end
end
