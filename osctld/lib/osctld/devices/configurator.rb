require 'libosctl'

module OsCtld
  # Used to configure the system to reflect osctld settings
  class Devices::Configurator
    include OsCtl::Lib::Utils::Log

    # @param owner [Devices::Owner]
    def initialize(owner)
      @owner = owner
    end

    # @param devices [Array<Devices::Device>]
    def init(devices)

    end

    # @param device [Devices::Device]
    def add_device(device)

    end

    # @param device [Devices::Device]
    def remove_device(device)

    end

    # @param devices [Array<Devices::Device>]
    def reconfigure(devices)

    end

    # @param changes [Hash]
    def apply_changes(changes)

    end

    # @param new_owner [Devices::Owner]
    def dup(new_owner)
      ret = super()
      ret.instance_variable_set('@owner', new_owner)
      ret
    end

    protected
    # @return [Devices::Owner]
    attr_reader :owner
  end
end
