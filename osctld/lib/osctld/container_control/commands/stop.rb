require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/container_control/utils/wall'

module OsCtld
  # Stop/shutdown/kill container
  #
  # Available stop modes:
  #
  # - `:stop` attempts a clean shutdown, falls back to kill
  # - `:shutdown` either shuts down the container cleanly, or fails
  # - `:kill` kills the container immediately
  class ContainerControl::Commands::Stop < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Wall::Frontend

      # @param mode [:stop, :shutdown, :kill]
      # @param opts [Hash] options
      # @option opts [Integer] :timeout how log to wait for clean shutdown
      # @option opts [String] :message
      # @return [true]
      def execute(mode, **opts)
        if !%i(stop shutdown kill).include?(mode)
          raise ArgumentError, "invalid stop mode '#{mode}'"
        end

        CGroup.thaw_tree(ct.cgroup_path) if mode == :kill

        if opts[:message] && ct.running?
          opts = opts.merge(message: make_message(opts[:message]))
        else
          opts.delete(:message)
        end

        ret =
          if %i(stop shutdown).include?(mode) && ct.running?
            exec_runner(args: [mode, opts.merge(halt_from_inside: true)])
          else
            fork_runner(args: [mode, opts])
          end

        if ret.ok?
          true

        elsif mode == :stop
          CGroup.thaw_tree(ct.cgroup_path)
          ret = fork_runner(args: [:kill, opts])
          ret.ok? || ret

        else
          ret
        end
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Wall::Runner

      def execute(mode, opts)
        if opts[:message]
          begin
            ct_wall(opts[:message])
          rescue LXC::Error
            # ignore
          end
        end

        send(:"do_#{mode}", opts)
      end

      protected
      def do_stop(opts)
        if do_shutdown(opts)[:status]
          ok
        else
          error('kill required')
        end
      end

      def do_shutdown(opts)
        run_halt if opts[:halt_from_inside]
        lxc_ct.shutdown(opts[:timeout])
        ok
      rescue LXC::Error
        error('unable to shutdown container')
      end

      def do_kill(opts)
        lxc_ct.stop
        ok
      rescue LXC::Error
        error('unable to kill container')
      end

      def run_halt
        pid = lxc_ct.attach do
          %w(halt poweroff shutdown).each do |cmd|
            begin
              LXC.run_command(cmd)
            rescue LXC::Error
              next
            end
          end
        end

        Process.wait(pid) if pid && pid > 1
      end
    end
  end
end
