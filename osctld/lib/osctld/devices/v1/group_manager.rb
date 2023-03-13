require 'libosctl'
require 'osctld/devices/manager'

module OsCtld
  class Devices::V1::GroupManager < Devices::Manager
    include OsCtl::Lib::Utils::Log

    def parent
      group.root? ? nil : group.parent
    end

    def children
      group.children + group.containers
    end

    def configurator_class
      Devices::V1::GroupConfigurator
    end

    protected
    alias_method :group, :owner
  end
end
