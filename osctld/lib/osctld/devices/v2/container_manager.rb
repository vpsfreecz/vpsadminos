require 'osctld/devices/manager'

module OsCtld
  class Devices::V2::ContainerManager < Devices::Manager
    def parent
      ct.group
    end

    def children
      []
    end

    def configurator_class
      Devices::V2::Configurator
    end

    protected
    alias_method :ct, :owner
  end
end
