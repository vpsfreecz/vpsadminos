require 'osctld/devices/manager'

module OsCtld
  class Devices::V2::GroupManager < Devices::Manager
    def parent
      group.parent
    end

    def children
      group.children
    end

    def configurator_class
      Devices::V2::Configurator
    end

    protected
    alias_method :group, :owner
  end
end
