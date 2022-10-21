require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Query container state
  class ContainerControl::Commands::State < ContainerControl::Command
    ContainerState = Struct.new(:id, :state, :init_pid)

    class Frontend < ContainerControl::Frontend
      # @return [ContainerState]
      def execute
        unless CGroup.abs_cgroup_path_exist?('memory', ct.cgroup_path)
          # If the container's memory cgroup does not exist, it is safe to say
          # that it is not running and we don't have to fork.
          return ContainerState.new(ct.id, :stopped, nil)
        end

        ret = fork_runner

        if ret.ok?
          ContainerState.new(ct.id, ret.data[:state].to_sym, ret.data[:init_pid])
        else
          ret
        end
      end
    end

    class Runner < ContainerControl::Runner
      def execute
        ok(state: lxc_ct.state, init_pid: lxc_ct.init_pid)
      end
    end
  end
end
