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
      # @option opts [IO, nil] :mnt_ns opened mount namespace
      # @option opts [String, nil] :chroot
      # @option opts [IO, nil] :root_dir opened chroot directory
      # @option opts [Boolean] :switch_to_system
      # @option opts [IO, nil] :stdout
      # @option opts [Proc] :block
      def execute(opts)
        ct.mount

        ret = fork_runner({
          args: [{
            ctrc: opts.fetch(:ctrc, ct.get_run_conf),
            ns_pid: opts[:ns_pid],
            mnt_ns: opts[:mnt_ns],
            chroot: opts[:chroot],
            root_dir: opts[:root_dir],
            switch_to_system: opts.fetch(:switch_to_system, true),
            block: opts[:block]
          }],
          keep_fds: [opts[:mnt_ns], opts[:root_dir]].compact,
          switch_to_system: false,
          stdout: opts[:stdout]
        }.compact)
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [Integer] :ns_pid
      # @option opts [IO, nil] :mnt_ns opened mount namespace
      # @option opts [String, nil] :chroot
      # @option opts [IO, nil] :root_dir opened chroot directory
      # @option opts [Boolean] :switch_to_system
      # @option opts [Proc] :block
      def execute(opts)
        sys = OsCtl::Lib::Sys.new
        reopened_root_dir = nil

        if opts[:mnt_ns]
          sys.setns_io(opts[:mnt_ns], OsCtl::Lib::Sys::CLONE_NEWNS)
        else
          sys.setns_path(
            File.join('/proc', opts[:ns_pid].to_s, 'ns', 'mnt'),
            OsCtl::Lib::Sys::CLONE_NEWNS
          )
        end

        root_dir = opts[:root_dir]
        if root_dir && opts[:chroot]
          reopened_root_dir = reopen_root_dir(sys, opts[:chroot], root_dir)
          root_dir = reopened_root_dir
        end

        if root_dir
          sys.fchdir_io(root_dir)
          sys.chroot('.')
          Dir.chdir('/')
        elsif opts[:chroot]
          sys.chroot(opts[:chroot])
        end

        if opts[:root_dir] || opts[:chroot]
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
            '/'
          )
        end

        ok(opts[:block].call)
      ensure
        reopened_root_dir&.close
      end

      protected

      # A directory descriptor opened before setns retains its original mount
      # reference and cannot see child mounts created only in the target mount
      # namespace. Reopen the path after setns, then bind the new descriptor to
      # the already-authenticated root by device and inode before using it.
      def reopen_root_dir(sys, path, expected)
        absolute_path = File.absolute_path(path)
        relative_path = absolute_path.delete_prefix('/')
        relative_path = '.' if relative_path.empty?

        namespace_root = File.open('/', File::RDONLY | File::NOFOLLOW)
        root_dir = sys.open_beneath(namespace_root, relative_path)

        actual_stat = root_dir.stat
        expected_stat = expected.stat
        unless actual_stat.dev == expected_stat.dev && actual_stat.ino == expected_stat.ino
          raise Errno::EXDEV, absolute_path
        end

        root_dir
      rescue StandardError
        root_dir&.close
        raise
      ensure
        namespace_root&.close
      end
    end
  end
end
