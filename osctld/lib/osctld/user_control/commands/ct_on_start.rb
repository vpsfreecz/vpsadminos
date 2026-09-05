require 'libosctl'
require 'osctld/net_config'
require 'osctld/process_identity'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtOnStart < UserControl::Commands::Base
    handle :ct_on_start

    CGROUP_DELEGATE_BUSY_RETRIES = 100
    CGROUP_DELEGATE_BUSY_RETRY_DELAY = 0.1
    CGROUP_DELEGATE_RETRYABLE_ERRORS = [
      Errno::EBUSY,
      Errno::EOPNOTSUPP,
      Errno::EINVAL
    ].freeze

    class NetworkSetupFailed < StandardError; end
    class InitIdentityFailed < StandardError; end

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      net_config = static_network_config(ct)
      init_identity = open_init_identity(ct) unless net_config.empty?
      with_claimed_lifecycle_event(ct, :on_start, after: :pre_start) do |run_conf|
        delegate_start_cgroups(ct)

        # Configure the system
        DistConfig.run(run_conf, :start)
        configure_static_network(init_identity, net_config)

        Hook.run(ct, :on_start)
        ok
      end
    rescue HookFailed, NetworkSetupFailed, InitIdentityFailed => e
      error(e.message)
    ensure
      init_identity&.close
    end

    protected

    def detect_init_pid(ct)
      pid = positive_pid(authenticated_run_conf&.init_pid)
      return pid if pid

      positive_pid(peer&.environment_variable('LXC_PID'))
    rescue StandardError => e
      log(:warn, ct, "Unable to detect init PID for start-time network setup: #{e.message}")
      nil
    end

    def open_init_identity(ct)
      init_pid = detect_init_pid(ct)
      unless init_pid
        raise InitIdentityFailed, 'unable to resolve current container init identity: PID is not available'
      end

      identity = ProcessIdentity.new(init_pid, namespaces: %i[net pid])

      if identity.pid == peer&.pid
        identity.close
        raise Errno::EPERM, 'container init process matches the lifecycle hook'
      end

      unless identity.in_cgroup_subtree?(ct.base_cgroup_path)
        identity.close
        raise Errno::EPERM, 'container init process is outside its cgroup'
      end

      lifecycle_identity = authenticated_run_conf&.lifecycle_identity
      unless lifecycle_identity && identity.direct_child_of?(lifecycle_identity)
        identity.close
        raise Errno::EPERM, 'container init process is not the lifecycle child'
      end

      identity
    rescue SystemCallError, IOError, ArgumentError => e
      identity&.close
      raise InitIdentityFailed,
            "unable to resolve current container init identity: #{e.message}"
    end

    def positive_pid(value)
      return unless value.respond_to?(:to_i)

      pid = value.to_i
      pid > 0 ? pid : nil
    end

    def static_network_config(ct)
      return [] unless ct.can_dist_configure_network?

      NetConfig.create(ct).export(configured_only: true)
    end

    def configure_static_network(init_identity, net_config)
      return if net_config.empty?

      if init_identity.nil?
        raise NetworkSetupFailed, 'network setup failed: container init PID is not available'
      end

      fork_static_network_setup(init_identity, net_config)
    end

    def fork_static_network_setup(init_identity, net_config)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        msg = nil
        status = 0

        begin
          unless init_identity.alive?
            raise Errno::ESRCH, 'container init process exited'
          end

          NetConfig.setup_in_netns(init_identity, net_config)
        rescue StandardError => e
          msg = "#{e.class}: #{e.message}"
          status = 1
        ensure
          w.write(msg) if msg
          w.close
        end

        exit!(status)
      end

      w.close
      msg = r.read
      r.close

      _, status = Process.wait2(pid)
      return if status.success?

      detail = msg.empty? ? "exited with status #{status.exitstatus}" : msg
      raise NetworkSetupFailed, "network setup failed: #{detail}"
    end

    def delegate_start_cgroups(ct)
      return unless CGroup.v2?

      uid = ct.user.ugid
      gid = ct.root_host_gid

      root_cgroup = CGroup.abs_cgroup_path(nil, ct.cgroup_path)

      delegate_start_cgroup_ancestors(ct, root_cgroup)

      CGroup.chown_delegated(
        root_cgroup,
        uid:,
        gid:
      )

      # The start path prepares this cgroup and the wrapper moves itself into
      # it, so v2 domain controllers cannot be enabled there initially. Once
      # start-host runs, LXC has moved the monitor/payload into child cgroups
      # and the cgroup namespace root can be delegated to nested managers such
      # as Docker.
      delegate_start_cgroup_controllers(ct, root_cgroup) do
        ensure_start_cgroup_empty!(ct)
      end

      # start-host can run before LXC has created the payload cgroup. If the
      # payload is already visible, make it writable as well; otherwise the
      # parent delegation above is the CT-level contract systemd can rely on.
      begin
        CGroup.chown_delegated(
          CGroup.abs_cgroup_path(nil, ct.payload_cgroup_path),
          uid:,
          gid:
        )
      rescue Errno::ENOENT
        nil
      end
    end

    def delegate_start_cgroup_ancestors(ct, root_cgroup)
      cgroup_fs = File.expand_path(CGroup.fs)
      path = File.dirname(File.expand_path(root_cgroup))
      ancestors = []

      loop do
        break if path == cgroup_fs || path == '/'
        break unless path.start_with?("#{cgroup_fs}/")

        ancestors << path
        path = File.dirname(path)
      end

      ancestors.reverse_each do |ancestor|
        delegate_start_cgroup_controllers(ct, ancestor)
      end
    end

    def delegate_start_cgroup_controllers(ct, root_cgroup)
      attempts = 0

      begin
        CGroup.delegate_available_controllers(root_cgroup) do
          yield if block_given?
        end
      rescue *CGROUP_DELEGATE_RETRYABLE_ERRORS => e
        if attempts < CGROUP_DELEGATE_BUSY_RETRIES
          attempts += 1
          sleep(CGROUP_DELEGATE_BUSY_RETRY_DELAY)
          retry
        end

        log(
          :warn,
          ct,
          "Unable to delegate cgroup v2 controllers on #{root_cgroup}: " \
          "#{e.message} after #{CGROUP_DELEGATE_BUSY_RETRIES} retries over " \
          "#{CGROUP_DELEGATE_BUSY_RETRIES * CGROUP_DELEGATE_BUSY_RETRY_DELAY} seconds; " \
          'nested cgroup managers may be unavailable'
        )
      end
    end

    def ensure_start_cgroup_empty!(ct)
      pids = CGroup.get_cgroup_pids(nil, ct.cgroup_path)
      return if pids.empty?

      # LXC moves its monitor itself before it creates the payload, creates the
      # payload with CLONE_INTO_CGROUP when available, and runs start-host from
      # the already placed monitor. A process left here is therefore an LXC
      # placement failure, not an identity osctld can safely repair: the cgroup
      # interface accepts only a numeric PID and cannot bind a write to our
      # held pidfd. Retry while LXC is settling, but never move an unidentified
      # or possibly reused PID.
      raise Errno::EBUSY,
            "unexpected processes remain in the container cgroup: #{pids.join(', ')}"
    end
  end
end
