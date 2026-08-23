require 'json'
require 'socket'
require 'osctld/console'
require 'osctld/container/lifecycle_executor'
require 'osctld/container/lifecycle_finalizer'
require 'osctld/container/recovery'
require 'osctld/lockable'
require 'osctld/cpu_scheduler'
require 'osctld/dist_config'
require 'osctld/commands/group/cgparam_apply'

module OsCtld
  module ContainerControl::Utils::Runscript
    module Frontend
      def with_execution_mode(run:, network:, &block)
        unless run
          raise ContainerControl::Error, 'container not running' unless ct.running?

          run_id = ct.lifecycle.active_run_id
          raise ContainerControl::Error, 'managed lifecycle run not found' unless run_id

          return block.call(:running, attachment_runner_options(run_id))
        end

        loop do
          request = ct.manipulate(self, block: true) do
            if ct.lifecycle.active_run_id.nil?
              ret = Commands::Group::CGParamApply.run(
                name: ct.group.name,
                pool: ct.pool.name,
                manipulation_lock: 'wait',
                only_policies: true
              )
              unless ret[:status]
                raise ContainerControl::Error,
                      "unable to reconcile ancestor cgroups: #{ret[:message]}"
              end
            end

            Daemon.get.with_lifecycle_admission do
              ct.lifecycle.request_execution(source: 'container-control')
            end
          end

          case request.action
          when :running
            return block.call(
              :running,
              attachment_runner_options(request.run_id)
            )

          when :wait
            changed = ct.lifecycle.wait_for_change(request.revision)
            if changed == :shutdown
              raise ContainerControl::Error, 'osctld is shutting down'
            end

          when :launch
            ret = with_execution_generation(request, network:, &block)
            next if ret == :retry

            return ret

          when :failed
            lifecycle_run = ct.lifecycle.run(request.run_id)
            raise ContainerControl::Error,
                  lifecycle_run&.fetch('error', nil) ||
                  'container lifecycle cleanup failed'

          when :blocked
            raise ContainerControl::Error, request.warning

          else
            raise ContainerControl::Error,
                  "unsupported execution lifecycle action #{request.action.inspect}"
          end
        end
      end

      def add_network_opts(opts)
        opts.update(
          init_script: File.join('/', File.basename(init_script.path)),
          net_config: NetConfig.create(ct).export
        )
      end

      def init_script
        return @init_script if @init_script

        f = Tempfile.create(['.runscript', '.sh'], ct.get_run_conf.rootfs)
        f.chmod(0o500)
        f.puts('#!/bin/sh')
        f.puts('echo ready')
        f.puts('read _')
        f.close

        @init_script = f
      end

      def cleanup_init_script
        @init_script && unlink_file(@init_script.path)
      end

      def unlink_file(path)
        File.unlink(path)
      rescue SystemCallError
        # pass
      end

      protected

      def attachment_runner_options(run_id)
        run = ct.lifecycle.run(run_id)
        unless run
          raise ContainerControl::Error,
                'managed lifecycle run not found'
        end

        {
          cgroup_path: run.fetch('resources').fetch('lxc_monitor'),
          lxc_config: run.fetch('resources').fetch('lxc_config'),
          on_spawn: proc do |pid|
            process_id = Daemon.get.with_lifecycle_admission do
              ct.lifecycle.register_attachment(run_id, pid:)
            end
            unless process_id
              raise ContainerControl::Error,
                    'container stopped before command attachment'
            end

            process_id
          end,
          on_reap: proc do |_pid, process_id|
            finish_attachment(run_id, process_id) if process_id
          end
        }
      end

      def finish_attachment(run_id, process_id)
        effect_id = ct.lifecycle.finish_process(run_id, process_id)
        return unless effect_id

        run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
          conf.run_id == run_id
        end
        return unless run_conf

        Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
      end

      def with_execution_generation(request, network:)
        effect_id = ct.lifecycle.claim_effect(request.run_id, :execute)
        return :retry unless effect_id

        acquired = Container::LifecycleExecutor.acquire(
          ct.pool,
          :start,
          effect_id
        )
        unless acquired
          ct.lifecycle.fail_launch(
            request.run_id,
            effect_id,
            'osctld is shutting down'
          )
          raise ContainerControl::Error, 'osctld is shutting down'
        end

        worker_set = ct.lifecycle.set_effect_worker(
          request.run_id,
          effect_id,
          Process.pid
        )
        ensure_execution_effect!(request.run_id, effect_id) if worker_set
        unless worker_set
          raise ContainerControl::Error,
                'transient lifecycle effect was superseded'
        end

        run_conf = ct.init_run_conf(run_id: request.run_id)
        ensure_execution_effect!(request.run_id, effect_id)
        run_conf.mount
        ensure_execution_effect!(request.run_id, effect_id)
        ct.mounts.prune
        ensure_execution_effect!(request.run_id, effect_id)
        DistConfig.run(run_conf, :pre_start)
        ensure_execution_effect!(request.run_id, effect_id)
        CpuScheduler.schedule_ct(run_conf)
        ensure_execution_effect!(request.run_id, effect_id)
        ct.cgparams.apply_cpuset_for_start(run_id: request.run_id)
        ensure_execution_effect!(request.run_id, effect_id)
        unless ct.lxc_config.configure(run_conf:)
          raise ContainerControl::Error,
                'unable to generate transient LXC configuration'
        end
        ensure_execution_effect!(request.run_id, effect_id)

        hook_paths = ct.netifs.flat_map do |netif|
          if netif.respond_to?(:run_hook_paths)
            netif.run_hook_paths(run_conf)
          else
            []
          end
        end
        recorded = ct.lifecycle.record_resources(
          request.run_id,
          {
            dataset: run_conf.dataset.to_s,
            rootfs: run_conf.rootfs,
            mounts: ct.mounts.all_entries.map(&:dump),
            console_socket: Console.socket_path(ct),
            lxc_config: ct.lxc_config.run_config_path(run_conf),
            apparmor_profile: ct.apparmor.profile_name(run_conf),
            apparmor_namespace: ct.apparmor.namespace(run_conf),
            network_hook_paths: hook_paths
          },
          effect_id:,
          intent_id: request.intent_id
        )
        unless recorded
          raise ContainerControl::Error,
                'transient lifecycle effect was superseded'
        end
        lifecycle_run = ct.lifecycle.run(request.run_id)
        wrapper_cgroup = lifecycle_run
                         .fetch('resources')
                         .fetch('wrapper_cgroup')

        wrapper_pid = nil
        runner_opts = {
          run_id: request.run_id.to_s,
          lxc_config: ct.lxc_config.run_config_path(run_conf),
          cgroup_path: wrapper_cgroup,
          reset_subtree_control: true,
          reset_subtree_control_path: run_conf.cgroup_path,
          on_spawn: proc do |pid|
            wrapper_pid = pid
            unless ct.lifecycle.mark_execution_launching(
              request.run_id,
              effect_id,
              pid
            )
              raise ContainerControl::Error,
                    'transient container execution was superseded'
            end
          end
        }

        mode = network ? :run_network : :run
        ret = yield(mode, runner_opts)

        ct.lifecycle.finish_effect(request.run_id, effect_id)
        finalize_execution_generation(ct, run_conf)

        case ct.lifecycle.wait_for_stop(request.run_id)
        when :clean
          ret
        when :quarantined
          raise ContainerControl::Error,
                'transient container generation was quarantined'
        when :failed, :cleanup_failed
          lifecycle_run = ct.lifecycle.run(request.run_id)
          raise ContainerControl::Error,
                lifecycle_run&.fetch('error', nil) ||
                'transient container cleanup failed'
        when :shutdown
          raise ContainerControl::Error, 'osctld is shutting down'
        else
          raise ContainerControl::Error,
                'transient container execution could not be stopped'
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        if run_conf && wrapper_pid
          ct.lifecycle.finish_effect(request.run_id, effect_id)
          finalize_execution_generation(ct, run_conf)
        elsif run_conf && ct.lifecycle.effect_current?(request.run_id, effect_id)
          ct.lifecycle.fail_launch(request.run_id, effect_id, e.message)
          ct.abort_run_conf(run_conf)
          cleanup_failed_execution_generation(request.run_id)
        end
        raise
      ensure
        if effect_id
          ct.lifecycle.effect_worker_exited(request.run_id, effect_id)
          Container::LifecycleExecutor.release(ct.pool, :start, effect_id)
        end
      end

      def cleanup_failed_execution_generation(run_id)
        Container::Recovery.new(ct).cleanup_generation(run_id)
        unless ct.lifecycle.other_runtime_generation?(run_id)
          CpuScheduler.unschedule_ct(ct)
        end
      rescue StandardError
        nil
      end

      def finalize_execution_generation(ct, run_conf)
        effect_id = ct.lifecycle.observe_wrapper_gone(run_conf.run_id)
        if effect_id
          Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
          return
        end

        run = ct.lifecycle.run(run_conf.run_id)
        return if run&.fetch('post_stop', false)

        begin
          Container::Recovery.new(ct).recover_state(run_id: run_conf.run_id)
        rescue Container::Recovery::Busy
          nil
        end
      end

      def ensure_execution_effect!(run_id, effect_id)
        return if ct.lifecycle.effect_current?(run_id, effect_id)

        raise ContainerControl::Error,
              'transient lifecycle effect was superseded'
      end
    end

    module Runner
      # Execute script in a stopped container
      # @param opts [Hash]
      # @option opts [String] :script path to the script relative to the rootfs
      # @option opts [IO] :stdin
      # @option opts [IO] :stdout
      # @option opts [IO] :stderr
      # @option opts [Array<IO>] :close_fds
      # @option opts [Boolean] :wait
      def runscript_run(opts)
        pid = Process.fork do
          cur_stdin = opts.fetch(:stdin, stdin)
          cur_stdout = opts.fetch(:stdout, stdout)
          cur_stderr = opts.fetch(:stderr, stderr)

          if cur_stdin
            $stdin.reopen(cur_stdin)
          else
            $stdin.close
          end

          $stdout.reopen(cur_stdout)
          $stderr.reopen(cur_stderr) if cur_stderr

          opts[:close_fds] && opts[:close_fds].each(&:close)

          setup_exec_run_env
          osctld_wrapper_callback

          cmd = [
            'lxc-execute',
            '-P', lxc_home,
            '-n', ctid,
            '-f', lxc_config,
            '-o', log_file,
            '-s', "lxc.environment=PATH=#{system_path.join(':')}",
            '-s', 'lxc.environment=HOME=/root',
            '-s', 'lxc.environment=USER=root',
            '--',
            opts[:script]
          ]

          # opts[:cmd] can contain an arbitrary command with multiple arguments
          # and quotes, so the mapping to process arguments is not clear. We use
          # the shell to handle this.
          Process.exec("exec #{cmd.join(' ')}")
        end

        if opts[:wait] === false
          pid
        else
          _, status = Process.wait2(pid)
          ok(status.exitstatus)
        end
      end

      # Start container with lxc-init, configure network and yield
      #
      # opts[:init_script] has to contain path to a script that will be executed
      # by lxc-init. The purpose of this script is to keep the container running
      # while the network is being configured and the user command is executed.
      # The script has to write `ready\n` to standard output, then block on read
      # from standard input and exit.
      #
      # @param opts [Hash]
      # @option opts [String] :init_script path to the script used to control
      #                                    the container
      # @option opts [Hash] :net_config
      def with_configured_network(opts)
        ret = nil

        # Pipes for communicating with opts[:init_script]
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe

        # Start the container with lxc-init
        init_pid = runscript_run(
          id: ctid,
          script: opts[:init_script],
          stdin: in_r,
          stdout: out_w,
          stderr: nil,
          close_fds: [in_w, out_r],
          wait: false
        )

        in_r.close
        out_w.close

        # Wait for the container to be started
        ready = out_r.readline.strip
        if ready == 'ready'
          # Configure network
          pid = lxc_ct.attach do
            setup_exec_env
            ENV['HOME'] = '/root'
            ENV['USER'] = 'root'
            NetConfig.import(opts[:net_config]).setup
          end

          _, status = Process.wait2(pid)

          # Execute user command
          ret = yield
        end

        # Closing in_w will bring down opts[:init_script] and stop the container
        in_w.close
        out_r.close

        _, status = Process.wait2(init_pid)
        ret || ok(status.exitstatus)
      end

      # Callback to osctld to authorize and relocate this exact lxc-execute
      # process from the transient generation's wrapper cgroup.
      def osctld_wrapper_callback
        s = UNIXSocket.new("/run/osctl/user-control/#{Process.uid}.sock")

        payload = {
          cmd: :ct_lxc_execute_start,
          opts: {
            id: ctid,
            pool:,
            run_id:,
            pid: Process.pid
          }
        }

        s.send("#{payload.to_json}\n", 0)

        ret = JSON.parse(s.readline, symbolize_names: true)
        s.close

        return if ret[:status]

        raise "Error during ct_lxc_execute_start callback: #{ret[:message]}"
      end
    end
  end
end
