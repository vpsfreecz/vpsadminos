require 'libosctl'
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

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      delegate_start_cgroups(ct)

      # Configure the system
      DistConfig.run(ct.run_conf, :start)

      Hook.run(ct, :on_start)
      ok
    rescue HookFailed => e
      error(e.message)
    end

    protected

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
