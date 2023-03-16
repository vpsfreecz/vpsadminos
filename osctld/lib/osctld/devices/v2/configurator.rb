require 'osctld/devices/configurator'

module OsCtld
  class Devices::V2::Configurator < Devices::Configurator
    # @return [String]
    attr_reader :prog_name

    def init(devices)
      get_prog(devices)
    end

    def reconfigure(devices)
      attach_prog(devices)
    end

    protected
    # @return [String] relative cgroup path
    def cgroup_path
      raise NotImplementedError
    end

    # @return [String] absolute cgroup path
    def abs_cgroup_path
      raise NotImplementedError
    end

    def attach_prog(devices)
      @prog_name = Devices::V2::BpfProgramCache.set(
        owner.pool.name,
        devices,
        abs_cgroup_path,
        prog_name: @prog_name,
      )
    end

    def get_prog(devices)
      @prog_name = Devices::V2::BpfProgramCache.get_prog_name(devices)
    end
  end
end
