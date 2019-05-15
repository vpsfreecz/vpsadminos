require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Read veth interface name
  class ContainerControl::Commands::VethName < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param index [Integer] interface index
      # @return [String]
      def execute(index)
        ret = pipe_runner(args: [index])
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param index [Integer] interface index
      def execute(index)
        ok(lxc_ct.running_config_item("lxc.net.#{index}.veth.pair"))
      end
    end
  end
end
