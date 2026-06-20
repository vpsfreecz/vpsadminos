require 'libosctl'
require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/process_identity'
require 'osctld/switch_user'

module OsCtld
  # Relocate mount from the host-shared directory into the container
  class ContainerControl::Commands::Mount < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option opts [String] :shared_dir path to the host-shared directory
      # @option opts [String] :src directory inside `:shared_dir` to relocate
      # @option opts [String] :dst target mountpoint
      # @return [true]
      def execute(opts)
        lease = nil
        expected_run_conf = ct.inclusively { ct.run_conf }
        if expected_run_conf && expected_run_conf.init_pid.nil?
          ct.refresh_init_pid(expected_run_conf:)
        end
        ret = nil

        ct.inclusively do
          run_conf = ct.run_conf
          unless ct.running? && run_conf && run_conf.init_pid
            ret = error_result('container not running or init PID not set')
            next
          end

          lease = run_conf.acquire_init_lease(namespaces: [:mnt], root: true)
          unless lease
            ret = error_result('container init identity is not available')
            next
          end
          identity = lease.identity

          identity.authenticate!(cgroup_path: ct.cgroup_path)

          unless ct.run_conf.equal?(run_conf) && run_conf.init_pid == identity.pid
            ret = error_result('container run changed while resolving init identity')
            next
          end

          ret = {
            args: [opts.merge(
              init_identity: identity,
              cgroup_path: ct.cgroup_path,
              root_host_uid: ct.root_host_uid,
              root_host_gid: ct.root_host_gid
            )],
            keep_fds: identity.files,
            switch_to_system: false
          }
        end

        return ret if ret.is_a?(ContainerControl::Result)

        ret = fork_runner(**ret)
        ret.ok? || ret
      rescue SystemCallError, IOError, Container::RunConfiguration::LifecycleError => e
        error_result("unable to resolve container init identity: #{e.message}")
      ensure
        lease&.close
      end

      protected

      def error_result(message)
        ContainerControl::Result.new(false, message:)
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [String] :shared_dir path to the host-shared directory
      # @option opts [String] :src directory inside `:shared_dir` to relocate
      # @option opts [String] :dst target mountpoint
      # @option opts [ProcessIdentity] :init_identity exact current-run init
      # @option opts [String] :cgroup_path expected container cgroup subtree
      # @option opts [Integer] :root_host_uid mapped container root UID
      # @option opts [Integer] :root_host_gid mapped container root GID
      def execute(opts)
        src = File.join(opts[:shared_dir], opts[:src])
        identity = opts.fetch(:init_identity)
        cgroup_path = opts.fetch(:cgroup_path)

        enter_container_mountns(identity, cgroup_path)
        prepare_mountpoint(
          opts[:dst],
          uid: opts.fetch(:root_host_uid),
          gid: opts.fetch(:root_host_gid)
        )

        if !wait_for_path(opts[:shared_dir])
          return error("Shared dir not found at: #{opts[:shared_dir]}")

        elsif !wait_for_path(src)
          return error("Source directory not found at: #{src}")
        end

        identity.authenticate!(cgroup_path:)
        relocate_mount(src, opts[:dst], create: false)
        ok
      rescue StandardError => e
        error("Exception (#{e.class}): #{e.message}")
      end

      protected

      def enter_container_mountns(identity, cgroup_path)
        authenticate_current_init!(identity, cgroup_path)
        sys = OsCtl::Lib::Sys.new
        raise Errno::ESRCH, 'container init process exited' unless sys.pidfd_alive?(identity.pidfd)

        sys.setns_io(identity.namespace(:mnt), OsCtl::Lib::Sys::CLONE_NEWNS)
        sys.fchdir_io(identity.root_dir)
        sys.chroot('.')
        Dir.chdir('/')
      end

      def authenticate_current_init!(identity, cgroup_path)
        identity.authenticate!(cgroup_path:)
        current_pid = lxc_ct.init_pid
        unless lxc_ct.running? && current_pid == identity.pid
          raise Errno::ESTALE, 'container init no longer belongs to the current LXC run'
        end

        identity.authenticate!(cgroup_path:)
      end

      def prepare_mountpoint(dst, uid:, gid:)
        pid = Process.fork do
          exit!(create_mountpoint_as(dst, uid:, gid:))
        end
        _, status = Process.wait2(pid)
        return if status.success?

        raise "mkdir -p #{dst.inspect} exited with #{status.exitstatus || 'signal'}"
      end

      def create_mountpoint_as(dst, uid:, gid:)
        SwitchUser.switch_to_system('', uid, gid, '/')
        FileUtils.mkdir_p(dst)
        true
      rescue StandardError => e
        warn("mkdir -p #{dst.inspect} failed: #{e.class}: #{e.message}")
        false
      end

      def relocate_mount(src, dst, create: true)
        FileUtils.mkpath(dst) if create
        sys = OsCtl::Lib::Sys.new
        sys.move_mount(src, dst)
        sys.make_private(dst)
      end
    end
  end
end
