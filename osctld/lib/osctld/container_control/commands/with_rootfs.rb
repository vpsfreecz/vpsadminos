require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'libosctl'

module OsCtld
  # Run code block in a mount namespace with the container's rootfs mounted
  #
  # The command can either attach to a mount namespace of an existing process,
  # or a new namespace is created.
  #
  # The block is given one argument: a string with the dataset's mountpoint.
  # The block's return value must be compatible with JSON.
  class ContainerControl::Commands::WithRootfs < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option opts [Container::RunConfiguration, nil] :ctrc
      # @option opts [Proc, nil] :block
      # @option opts [IO, nil] :mount_ns_io
      # @option opts [Integer, nil] :ns_pid
      # @option opts [Boolean] :mount
      # @option opts [Boolean] :recursive
      # @option opts [Array<IO>] :keep_fds
      # @option opts [Array<IO>] :pass_fds
      def execute(opts)
        keep_fds = opts.fetch(:keep_fds, []).compact
        pass_fds = opts.fetch(:pass_fds, []).compact

        if opts[:mount_ns_io]
          ns_io = opts[:mount_ns_io]
          keep_fds << ns_io
        elsif opts[:ns_pid]
          ns_io = File.open(File.join(
            '/proc', opts[:ns_pid].to_s, 'ns', 'mnt'
          ))
          pass_fds << ns_io
        else
          ns_io = nil
        end

        ret = fork_runner(
          args: [{
            dataset: opts.fetch(:ctrc, ct.get_run_conf).dataset,
            mount_ns_io: ns_io,
            block: opts[:block],
            mount: opts.fetch(:mount, true),
            recursive: opts.fetch(:recursive, true),
          }],
          switch_to_system: false,
          keep_fds: keep_fds,
          pass_fds: pass_fds,
        )
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [Proc, nil] :block
      # @option opts [OsCtl::Lib::Zfs::Dataset] :dataset
      # @option opts [IO, nil] :mount_ns_io
      # @option opts [Boolean] :mount
      # @option opts [Boolean] :recursive
      def execute(opts)
        sys = OsCtl::Lib::Sys.new

        if opts[:mount_ns_io]
          sys.setns_io(opts[:mount_ns_io], OsCtl::Lib::Sys::CLONE_NEWNS)
        else
          sys.unshare_ns(OsCtl::Lib::Sys::CLONE_NEWNS)
        end

        if opts[:mount]
          opts[:dataset].mount(recursive: opts[:recursive])
        end

        if opts[:block]
          ok(opts[:block].call(opts[:dataset].mountpoint))
        else
          ok
        end
      end
    end
  end
end
