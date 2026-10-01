require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  class ContainerControl::Commands::Unfreeze < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [true]
      def execute
        # Match freeze: liblxc controls the guest from the host-side context,
        # without an unnecessary running-container namespace transition.
        ret = fork_runner
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute
        lxc_ct.unfreeze
        ok
      end
    end
  end
end
