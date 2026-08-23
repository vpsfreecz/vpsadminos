require 'json'
require 'tempfile'

module OsCtld
  module Utils::SwitchUser
    def ct_attach(
      ct,
      *args,
      cgroup_path: ct.entry_cgroup_path,
      lifecycle: false
    )
      attachment = nil
      if lifecycle
        run_id = ct.lifecycle.active_run_id
        pid = client_pid
        unless run_id && pid
          raise CommandFailed, 'managed lifecycle attachment is unavailable'
        end

        process_id = Daemon.get.with_lifecycle_admission do
          ct.lifecycle.register_attachment(run_id, pid:)
        end
        unless process_id
          raise CommandFailed,
                'container stopped before command attachment'
        end
        attachment = {
          pool: ct.pool.name,
          id: ct.id,
          run_id: run_id.to_s,
          process_id:
        }
      end

      {
        cmd: ::OsCtld.bin('osctld-ct-exec'),
        args: args.map(&:to_s),
        env: ENV.select { |k, _v| k.start_with?('BUNDLE') || k.start_with?('GEM') }.to_h,
        settings: {
          user: ct.user.sysusername,
          ugid: ct.user.ugid,
          homedir: ct.user.homedir,
          cgroup_path:,
          prlimits: ct.prlimits.export,
          syslogns_pid: ct.init_pid,
          attachment:
        }
      }
    rescue StandardError
      ct.lifecycle.finish_process(run_id, process_id) \
        if lifecycle && run_id && process_id
      raise
    end

    def ct_su_cgroup_path(ct)
      File.join(
        CGroup::ROOT_GROUP,
        'admin',
        "pool.#{ct.pool.name}",
        "user.#{ct.user.name}"
      )
    end

    # Run a command `cmd` within container `ct`
    # @param ct [Container]
    # @param cmd [Array<String>] command to execute
    # @param opts [Hash] options
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    # @option opts [Boolean] :run run the container if it is stopped?
    # @option opts [Boolean] :network setup network if the container is run?
    # @option opts [Array<Integer>, Symbol] :valid_rcs
    # @return [OsCtl::Lib::SystemCommandResult]
    def ct_syscmd(ct, cmd, opts = {})
      opts[:valid_rcs] ||= []
      log(:work, ct, cmd)

      ContainerControl::Commands::Syscmd.run!(ct, cmd, opts)
    end
  end
end
