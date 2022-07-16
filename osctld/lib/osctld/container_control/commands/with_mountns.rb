require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'libosctl'

module OsCtld
  # Run code block in a process within a specified mount ns
  #
  # The block's return value must be compatible with JSON.
  class ContainerControl::Commands::WithMountns < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option opts [Container::RunConfiguration, nil] :ctrc
      # @option opts [Integer] :ns_pid
      # @option opts [String, nil] :chroot
      # @option opts [Boolean] :switch_to_system
      # @option opts [Proc] :block
      def execute(opts)
        ct.mount

        ret = fork_runner(
          args: [{
            ctrc: opts.fetch(:ctrc, ct.get_run_conf),
            ns_pid: opts[:ns_pid],
            chroot: opts[:chroot],
            switch_to_system: opts.fetch(:switch_to_system, true),
            block: opts[:block],
          }],
          switch_to_system: false,
        )
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [Integer] :ns_pid
      # @option opts [String, nil] :chroot
      # @option opts [Boolean] :switch_to_system
      # @option opts [Proc] :block
      def execute(opts)
        sys = OsCtl::Lib::Sys.new
        sys.setns_path(
          File.join('/proc', opts[:ns_pid].to_s, 'ns', 'mnt'),
          OsCtl::Lib::Sys::CLONE_NEWNS,
        )

        if opts[:chroot]
          sys.chroot(opts[:chroot])

          # After chroot, we can no longer access syslog logger. Log to stdout
          # instead, which will be picked up by osctld supervisor and sent to
          # syslog from there.
          OsCtl::Lib::Logger.setup(:stdout)
        end

        if opts[:switch_to_system]
          SwitchUser.switch_to_system(
            '',
            opts[:ctrc].ct.root_host_uid,
            opts[:ctrc].ct.root_host_gid,
            '/',
          )
        end

        ok(opts[:block].call)
      end
    end
  end
end
