require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Stop by executing halt inside the container
  class ContainerControl::Commands::StopByHalt < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Wall::Frontend

      # @param opts [Hash] options
      # @option opts [String, nil] :message
      # @return [true]
      def execute(**opts)
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        msg = if opts[:message]
                make_message(opts[:message])
              end

        ret = exec_runner(
          args: [{ message: msg }],
          switch_extra_namespaces: false
        )
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Wall::Runner

      # @param opts [Hash] options
      # @option opts [String, nil] :message
      # @return [Integer] exit status
      def execute(opts)
        if opts[:message]
          begin
            ct_wall(opts[:message])
          rescue LXC::Error
            # ignore
          end
        end

        exit_status = lxc_attach_wait do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'
          LXC.run_command('halt')
        end

        if exit_status == 0
          ok
        else
          error("halt failed with exit status #{exit_status}")
        end
      end
    end
  end
end
