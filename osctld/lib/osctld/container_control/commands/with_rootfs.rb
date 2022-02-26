require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'libosctl'

module OsCtld
  # Run code block in a process where / is the container's root filesystem
  #
  # The block's return value must be compatible with JSON.
  class ContainerControl::Commands::WithRootfs < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option opts [Container::RunConfiguration, nil] :ctrc
      # @option opts [Proc] :block
      def execute(opts)
        ct.mount

        ret = fork_runner(
          args: [{
            ctrc: opts.fetch(:ctrc, ct.get_run_conf),
            block: opts[:block],
          }],
          switch_to_system: false,
        )
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [Proc] :block
      # @option opts [Container::RunConfiguration] :ctrc
      def execute(opts)
        sys = OsCtl::Lib::Sys.new
        sys.chroot(opts[:ctrc].rootfs)

        SwitchUser.switch_to_system(
          '',
          opts[:ctrc].ct.root_host_uid,
          opts[:ctrc].ct.root_host_gid,
          '/',
        )

        ok(opts[:block].call)
      end
    end
  end
end
