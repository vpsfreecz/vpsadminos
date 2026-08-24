require 'json'
require 'libosctl'
require 'osctld/cgroup'
require 'osctld/container_control/command'
require 'osctld/cpu_scheduler'
require 'osctld/hook'
require 'osctld/process_identity'

module OsCtld
  # Out-of-band recovery for unresponsive container generations.
  class Container::Recovery
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    OUTCOMES = %i[cleaned quarantined partial blocked ambiguous].freeze
    INTERNAL_ADMISSION = {
      internal: true,
      continuation: true,
      recovery: true
    }.freeze
    class Busy < StandardError; end

    # @param ct [Container]
    def initialize(ct)
      @ct = ct
    end

    # Rediscover an exact generation's LXC state.
    def recover_state(run_id: nil, admission: INTERNAL_ADMISSION)
      run = resolve_run(run_id)
      run_id = load_run_id(run)
      unless run['role'] == 'active' && ct.lifecycle.active_run_id == run_id
        raise ArgumentError, 'state recovery is available only for the active lifecycle run'
      end

      reconciliation_id = Daemon.get.with_lifecycle_admission(**admission) do
        ct.lifecycle.begin_reconciliation(
          run_id,
          source: 'state_recovery'
        )
      end
      raise Busy, 'container lifecycle reconciliation is fenced' unless reconciliation_id

      begin
        supersede_stale_effect(run_id)
        run = ct.lifecycle.run(run_id)
        original_runtime_state = ct.runtime_state
        state_result = ContainerControl::Commands::State.run!(ct)
        current_state = state_result.state
        init_pid = state_result.init_pid
        execution_run = run.fetch('kind', 'container') == 'execution'

        unless ct.lifecycle.commit_reconciliation(run_id, reconciliation_id)
          return {
            runtime_state: current_state,
            run_id: run_id.to_s,
            lifecycle_revision: ct.lifecycle.revision,
            yielded_to_callback: true
          }
        end

        if execution_run
          ct.set_runtime_state(:stopped)
          logical_observed = false
        else
          logical_observed =
            ct.observe_run_state(run_id, current_state, init_pid:)
        end
        ct.lifecycle.observe_state(run_id, current_state, init_pid:, source: 'recovery')

        followup =
          if current_state == :stopped && run['phase'] == 'preparing' \
              && exact_run_conf(run_id).nil?
            reconcile_unlaunched(run_id)
          elsif current_state == :stopped
            recover_stopped_run(run_id)
          elsif execution_run \
              || ct.lifecycle.desired_state == :stopped \
              || replacement_requested?(run)
            [:stop, ct.lifecycle.current_intent_id]
          end

        if logical_observed \
            && current_state == :running \
            && ct.lifecycle.claim_reconciliation_state_effects(
              run_id,
              reconciliation_id,
              current_state
            )
          publish_state_effects(
            run_id,
            reconciliation_id,
            current_state,
            init_pid
          )
        elsif !execution_run \
            && original_runtime_state != current_state \
            && ct.runtime_state == current_state
          Eventd.report(
            :runtime_state,
            pool: ct.pool.name,
            id: ct.id,
            runtime_state: current_state,
            runtime_state_error: nil
          )
        end

        Eventd.report(
          :runtime_state_recovery,
          pool: ct.pool.name,
          id: ct.id,
          run_id: run_id.to_s,
          runtime_state: ct.runtime_state,
          runtime_state_error: ct.runtime_state_error
        )

        result = {
          runtime_state: ct.runtime_state,
          run_id: run_id.to_s,
          lifecycle_revision: ct.lifecycle.revision
        }
      rescue ContainerControl::Error => e
        if ct.lifecycle.commit_reconciliation(run_id, reconciliation_id)
          ct.set_runtime_state_unknown(
            source: :lxc_state_observation,
            message: e.message
          )
        end
        raise
      ensure
        effect_id = ct.lifecycle.finish_reconciliation(
          run_id,
          reconciliation_id
        )
        if effect_id
          run_conf = exact_run_conf(run_id)
          if run_conf
            Container::LifecycleFinalizer.spawn(
              ct,
              run_conf,
              effect_id
            )
          end
        end
      end

      run_reconciliation_followup(followup) if followup
      result
    end

    def freeze_generation(run_id = nil)
      run = resolve_run(run_id)
      CGroup.freeze_tree(run.fetch('resources').fetch('cgroup_root'))
    end

    def thaw_generation(run_id = nil)
      run = resolve_run(run_id)
      CGroup.thaw_tree(run.fetch('resources').fetch('cgroup_root'))
    end

    # Kill exact-generation processes with PID reuse protection.
    # @return [Array<Hash>]
    def kill_generation(run_id = nil, signal: 'KILL')
      run = resolve_run(run_id)
      root = run.fetch('resources').fetch('cgroup_root')

      generation_identities(root).filter_map do |identity|
        next unless identity.alive?
        next unless CGroup.get_tree_pids(root).include?(identity.pid)
        next unless identity.alive?

        log(:info, "kill -SIG#{signal} #{identity.pid}")

        begin
          Process.kill(signal, identity.pid)
          identity.dump.merge('signal' => signal, 'delivered' => true)
        rescue Errno::ESRCH
          nil
        end
      end
    end

    # Backward-compatible name used by stop/recovery callers.
    def kill_all(signal: 'KILL')
      kill_generation(nil, signal:)
    end

    # Clean requested resources and, when full isolation is proven, release the
    # active slot even if uninterruptible tasks keep generation cgroups busy.
    #
    # @param run_id [String, Container::RunId, nil]
    # @param cleanup [String, Array<String>]
    # @param force [Boolean]
    # @return [Hash]
    def cleanup(
      run_id: nil,
      cleanup: 'all',
      force: false,
      admission: INTERNAL_ADMISSION,
      &progress
    )
      requested = cleanup == 'all' ? %w[cgroups netifs] : Array(cleanup)
      run = resolve_run(run_id, allow_none: run_id.nil?)
      unless run
        return Daemon.get.with_lifecycle_task(
          kind: :container_recovery_without_run,
          details: { pool: ct.pool.name, id: ct.id },
          **admission
        ) do
          cleanup_without_run(requested, force:, &progress)
        end
      end

      run_id = load_run_id(run)
      recovery_lease = Daemon.get.with_lifecycle_admission(**admission) do
        ct.lifecycle.begin_recovery(run_id)
      end
      completed = []
      hazards = []
      evidence = {
        'observed_at' => Time.now.to_f,
        'requested' => requested,
        'runtime_state' => ct.runtime_state.to_s,
        'runtime_state_source' => 'osctld-cache'
      }

      if recovery_lease.busy
        hazards << 'another recovery worker still owns this generation'
        evidence['recovery_workers'] = recovery_lease.blocking_workers
        return result(:blocked, run_id, requested:, completed:, evidence:, hazards:)
      end

      if recovery_lease.blocking_workers.any?
        hazards << 'a lifecycle worker can still publish generation side effects'
        evidence['recovery_workers'] = recovery_lease.blocking_workers
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.park_recovery(run_id, recovery_lease.id)
        return result(:blocked, run_id, requested:, completed:, evidence:, hazards:)
      end

      superseded_effect = recovery_lease.superseded_effect
      if superseded_effect
        evidence['superseded_effect'] = superseded_effect
        release_effect(superseded_effect)
      end

      if run['role'] != 'residual' && ct.runtime_state != :stopped && !force
        hazards << 'LXC is not stopped'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.end_recovery(run_id, recovery_lease.id)
        return result(
          :blocked,
          run_id,
          requested:,
          completed:,
          evidence:,
          hazards:
        )
      end

      root = run.fetch('resources').fetch('cgroup_root')
      if requested.include?('cgroups')
        freeze_generation(run_id)
        begin
          CGroup.prevent_forks(root)
          kills = kill_generation(run_id)
        ensure
          thaw_generation(run_id)
        end
      else
        kills = []
      end

      evidence['kills'] = kills
      survivors = generation_process_evidence(root, kills:)
      evidence['survivors'] = survivors
      evidence['manager_processes'] = manager_process_evidence(run)

      if evidence['manager_processes'].any? { |manager| manager['alive'] }
        hazards << 'wrapper or lxc-start management process is still alive'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.park_recovery(run_id, recovery_lease.id)
        return result(:blocked, run_id, requested:, completed:, evidence:, hazards:)
      end

      if manager_identity_ambiguous?(run, evidence['manager_processes'])
        hazards << 'lifecycle manager absence cannot be proven'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.park_recovery(run_id, recovery_lease.id)
        return result(:ambiguous, run_id, requested:, completed:, evidence:, hazards:)
      end

      all_killed = survivors.all? do |process|
        process['kill_delivered'] || process['fatal_signal_pending']
      end
      unless all_killed
        hazards <<
          'not all surviving generation processes have SIGKILL pending'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.park_recovery(run_id, recovery_lease.id)
        return result(:blocked, run_id, requested:, completed:, evidence:, hazards:)
      end

      if requested.include?('netifs')
        network_result = cleanup_netifs(run_id) do |veth, routes|
          yield(veth, routes) if block_given?
        end
        evidence['network'] = network_result
        hazards.concat(network_result.fetch('hazards'))
        completed << 'netifs' if network_result.fetch('complete')
      end

      unless requested.include?('cgroups')
        hazards << 'generation cgroups were not requested for cleanup'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.end_recovery(run_id, recovery_lease.id)
        return result(:partial, run_id, requested:, completed:, evidence:, hazards:)
      end

      begin
        cleanup_generation(run_id)
        policy_root = cleanup_policy_root(run_id)
        if policy_root
          evidence['policy_root'] = policy_root
          unless policy_root.fetch('complete')
            hazards << 'stable policy cgroup root could not be removed'
          end
        end
        completed << 'cgroups'
        survivors = []
        unless ct.lifecycle.other_runtime_generation?(run_id)
          CpuScheduler.unschedule_ct(ct)
        end
      rescue SystemCallError => e
        evidence['cgroup_error'] = "#{e.class}: #{e.message}"
      end

      if completed.include?('cgroups') && survivors.empty?
        artifact_errors = cleanup_generation_artifacts(run_id)
        if artifact_errors.empty?
          finish_clean_recovery(
            run_id,
            recovery_lease.id,
            evidence,
            policy_root_removed: policy_root&.fetch('complete', false) || false
          )
          outcome = hazards.empty? ? :cleaned : :partial
          return result(outcome, run_id, requested:, completed:, evidence:, hazards:)
        end

        evidence['artifact_errors'] = artifact_errors
        hazards.concat(artifact_errors)
        was_active = run['role'] == 'active'
        if run['role'] == 'residual'
          ct.lifecycle.record_partial_recovery(
            run_id,
            recovery_id: recovery_lease.id,
            evidence:,
            hazards:
          )
          ct.lifecycle.end_recovery(run_id, recovery_lease.id)
        else
          quarantine = ct.lifecycle.quarantine(
            run_id,
            recovery_id: recovery_lease.id,
            evidence:,
            hazards:
          )
          unless quarantine
            raise ContainerControl::Error,
                  'lifecycle generation quarantine was superseded'
          end

          effect, restart_intent_id = quarantine
          release_effect(effect)
          detach_run_configuration(run_id, preserve: true)
          restart_if_requested(restart_intent_id)
        end

        return result(
          :partial,
          run_id,
          requested:,
          completed:,
          evidence:,
          hazards:,
          active_slot_released: was_active
        )
      end

      hazards << 'generation resources could not be removed'
      if survivors.any?
        hazards << 'unkillable processes retain mount namespace and dataset references'
      end
      hazards << 'already-entered kernel or ZFS operations may complete later'

      if run['role'] == 'residual'
        ct.lifecycle.record_partial_recovery(
          run_id,
          recovery_id: recovery_lease.id,
          evidence:,
          hazards:
        )
        ct.lifecycle.end_recovery(run_id, recovery_lease.id)
        return result(:quarantined, run_id, requested:, completed:, evidence:, hazards:)
      end

      was_active = run['role'] == 'active'
      quarantine = ct.lifecycle.quarantine(
        run_id,
        recovery_id: recovery_lease.id,
        evidence:,
        hazards:
      )
      unless quarantine
        raise ContainerControl::Error,
              'lifecycle generation quarantine was superseded'
      end

      effect, restart_intent_id = quarantine
      release_effect(effect)
      detach_run_configuration(run_id, preserve: true)
      restart_if_requested(restart_intent_id)

      result(
        :quarantined,
        run_id,
        requested:,
        completed:,
        evidence:,
        hazards:,
        active_slot_released: was_active
      )
    rescue ContainerControl::Error => e
      if recovery_lease && !recovery_lease.busy
        ct.lifecycle.end_recovery(run_id, recovery_lease.id)
      end
      result(
        :blocked,
        run_id || 'unknown',
        requested: cleanup == 'all' ? %w[cgroups netifs] : Array(cleanup),
        completed: [],
        evidence: {},
        hazards: [e.message]
      )
    ensure
      if recovery_lease && !recovery_lease.busy
        ct.lifecycle.park_recovery(run_id, recovery_lease.id)
      end
    end

    # Cleanup after the container or leave it represented as a residual.
    def cleanup_or_taint
      ret = cleanup
      !%i[blocked ambiguous].include?(ret[:outcome])
    rescue StandardError => e
      log(:warn, "Failed to recover container: #{e.class}: #{e.message}")
      false
    end

    # Remove exact-generation cgroups.
    def cleanup_generation(run_id = nil)
      run = resolve_run(run_id)
      resources = run.fetch('resources')

      if resources['cgroup_root'] == ct.base_cgroup_path
        %w[host_effects lxc_payload lxc_monitor lxc_pivot].each do |name|
          CGroup.rmpath_all(resources.fetch(name))
        end
      else
        CGroup.rmpath_all(resources.fetch('cgroup_root'))
      end
    end

    def cleanup_legacy_cgroups
      [
        File.join(ct.base_cgroup_path, 'host-effects'),
        ct.legacy_wrapper_cgroup_path,
        File.join(ct.legacy_cgroup_path, "lxc.payload.#{ct.id}"),
        File.join(ct.legacy_cgroup_path, "lxc.monitor.#{ct.id}"),
        File.join(ct.legacy_cgroup_path, "lxc.pivot.#{ct.id}")
      ].each { |path| CGroup.rmpath_all(path) }
    end

    # Backward-compatible method used by existing callers/specs.
    def cleanup_cgroups
      cleanup_generation
    end

    # Find and remove left-over network interfaces used by the container.
    def cleanup_netifs(run_id = nil)
      run = run_id && resolve_run(run_id)
      interfaces = run&.dig('resources', 'network_interfaces')

      if interfaces&.any?
        return cleanup_recorded_netifs(load_run_id(run), interfaces) do |veth, routes|
          yield(veth, routes) if block_given?
        end
      end

      cleanup_discovered_netifs do |veth, routes|
        yield(veth, routes) if block_given?
      end
    end

    def cleanup_recorded_netifs(run_id, interfaces)
      removed = []
      retained = []

      interfaces.each_value do |interface|
        veth = interface['veth']
        next unless veth

        routes = interface.fetch('routes', {}).values.flatten

        if veth_in_use_by_other_generation?(veth, run_id)
          retained << veth
          next
        end

        yield(veth, routes) if block_given?
        remove_veth(veth)
        removed << veth
      end

      {
        'complete' => retained.empty?,
        'mode' => 'recorded',
        'removed' => removed,
        'retained' => retained,
        'hazards' => retained.map do |veth|
          "network interface #{veth} is referenced by another lifecycle generation"
        end
      }
    end

    def cleanup_discovered_netifs
      veths = {}

      [4, 6].each do |ip_v|
        routes = RouteList.new(ip_v)

        ct.netifs.each do |netif|
          next if netif.type != :routed

          netif.routes.each_version(ip_v) do |route|
            veth = routes.veth_of(route)
            next unless veth

            log(:info, "Found route #{route.addr.to_string} on #{veth}")
            veths[veth] ||= []
            veths[veth] << route
          end
        end
      end

      removed = []
      retained = []

      veths.each do |veth, routes|
        found = container_using_veth(veth)

        if found
          log(:info, "Interface #{veth} is used by container #{found.ident}")
          retained << veth
        else
          yield(veth, routes) if block_given?
          remove_veth(veth)
          removed << veth
        end
      end

      {
        'complete' => retained.empty?,
        'mode' => 'legacy-route-discovery',
        'removed' => removed,
        'retained' => retained,
        'hazards' => [
          'network cleanup used legacy route discovery',
          *retained.map do |veth|
            "network interface #{veth} is used by another container"
          end
        ]
      }
    end

    def resolve_run(run_id = nil, allow_none: false)
      lifecycle = ct.lifecycle

      if run_id
        runs = lifecycle.runs.values
        key = run_id.respond_to?(:to_s) ? run_id.to_s : run_id
        matches = runs.select do |run|
          id = load_run_id(run)
          id.to_s == key || id.key == key
        end
        raise ArgumentError, "lifecycle run '#{key}' not found" if matches.empty?
        raise ArgumentError, "lifecycle run '#{key}' is ambiguous" if matches.length > 1

        return matches.first
      end

      lifecycle_snapshot = lifecycle.snapshot
      runs = lifecycle_snapshot.fetch('runs')
      active_id = lifecycle_snapshot['active_run_id']
      active = active_id && runs[active_id]
      return active if active

      residuals = runs.values.select { |run| run['role'] == 'residual' }
      unless residuals.empty?
        raise ArgumentError, 'multiple residual runs found, use --run-id' if residuals.length > 1

        return residuals.first
      end

      unclean_history = runs.values.select do |run|
        run['role'] == 'history' && run['phase'] != 'clean'
      end
      if unclean_history.length > 1
        raise ArgumentError, 'multiple unclean historical runs found, use --run-id'
      elsif unclean_history.length == 1
        return unclean_history.first
      end

      return if allow_none

      raise ArgumentError, 'no recoverable lifecycle run found'
    end

    def cleanup_without_run(requested, force:)
      completed = []
      hazards = []
      evidence = {
        'observed_at' => Time.now.to_f,
        'requested' => requested,
        'runtime_state' => ct.runtime_state.to_s,
        'runtime_state_source' => 'osctld-cache',
        'lifecycle_target' => 'none'
      }

      if ct.runtime_state != :stopped && !force
        hazards << 'LXC is not stopped'
        return result(
          :blocked,
          nil,
          requested:,
          completed:,
          evidence:,
          hazards:
        )
      end

      if requested.include?('cgroups')
        if ct.lifecycle.policy_tainted?
          policy_root = cleanup_policy_root
          evidence['policy_root'] = policy_root
          unless policy_root.fetch('complete')
            hazards << 'stable policy cgroup root could not be removed'
            return result(
              :blocked,
              nil,
              requested:,
              completed:,
              evidence:,
              hazards:
            )
          end
        else
          begin
            cleanup_legacy_cgroups
          rescue SystemCallError => e
            evidence['cgroup_error'] = "#{e.class}: #{e.message}"
            hazards << 'legacy cgroup resources could not be removed'
            return result(
              :blocked,
              nil,
              requested:,
              completed:,
              evidence:,
              hazards:
            )
          end
        end

        completed << 'cgroups'
        evidence['cgroups'] = {
          'mode' => policy_root ? 'stable-policy-root' : 'legacy-paths',
          'root' => ct.base_cgroup_path
        }
        if policy_root
          ct.lifecycle.clear_policy_taint_after_recovery(
            policy_root_removed: true
          )
        end
      end

      if requested.include?('netifs')
        network_result = cleanup_netifs do |veth, routes|
          yield(veth, routes) if block_given?
        end
        evidence['network'] = network_result
        hazards.concat(network_result.fetch('hazards'))
        completed << 'netifs' if network_result.fetch('complete')
      end

      outcome =
        if completed.length == requested.length && hazards.empty?
          :cleaned
        else
          :partial
        end

      result(
        outcome,
        nil,
        requested:,
        completed:,
        evidence:,
        hazards:
      )
    end

    def log_type
      "recover=#{ct.pool.name}:#{ct.id}"
    end

    class RouteList
      include OsCtl::Lib::Utils::Log
      include OsCtl::Lib::Utils::System

      def initialize(ip_v)
        @index = {}

        JSON.parse(syscmd("ip -#{ip_v} -json route list").output).each do |route|
          next unless route['dev'].start_with?('veth')

          index[route['dst']] = route['dev']
        end
      end

      def veth_of(route)
        index[key(route)]
      end

      protected

      attr_reader :index

      def key(route)
        if (route.addr.ipv4? && route.addr.prefix == 32) \
            || (route.addr.ipv6? && route.addr.prefix == 128)
          route.addr.to_s
        else
          route.addr.to_string
        end
      end
    end

    protected

    attr_reader :ct

    def recover_stopped_run(run_id)
      run_conf = exact_run_conf(run_id)
      run = ct.lifecycle.run(run_id)
      execution_run = run.fetch('kind', 'container') == 'execution'

      unless run['post_stop']
        begin
          ct.netifs.take_down
        rescue StandardError => e
          log(:warn, "Unable to take down recovered network interfaces: #{e.message}")
        end

        ct.stopped(run_id)
        unless execution_run
          Eventd.report(
            :runtime_state,
            pool: ct.pool.name,
            id: ct.id,
            runtime_state: :aborting,
            runtime_state_error: nil
          )
          Eventd.report(
            :runtime_state,
            pool: ct.pool.name,
            id: ct.id,
            runtime_state: :stopped,
            runtime_state_error: nil
          )
        end
      end

      effect_id =
        unless manager_alive?(ct.lifecycle.run(run_id))
          ct.lifecycle.observe_wrapper_gone(run_id)
        end
      effect_id ||= ct.lifecycle.observe_post_stop(
        run_id,
        aborted: true,
        reboot: !execution_run && (run_conf&.reboot? || false)
      )
      if effect_id && run_conf
        Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
      elsif effect_id
        ct.lifecycle.fail_cleanup(
          run_id,
          effect_id,
          'exact run configuration is missing'
        )
      end
    end

    def publish_state_effects(run_id, owner_id, state, init_pid)
      Eventd.report(
        :runtime_state,
        pool: ct.pool.name,
        id: ct.id,
        runtime_state: state,
        runtime_state_error: nil
      )
      return unless state.to_sym == :running

      ct.pool.fulfil_autostart(ct)
      ct.pool.fulfil_reboot(ct)

      if init_pid
        Eventd.report(
          :ct_init_pid,
          pool: ct.pool.name,
          id: ct.id,
          init_pid:
        )
      end

      error = nil
      begin
        Hook.run(ct, :post_start, init_pid:)
      rescue StandardError => e
        error = "#{e.class}: #{e.message}"
        log(:warn, "Post-start hook failed for #{ct.ident}: #{error}")
      ensure
        ct.lifecycle.complete_running_effects(
          run_id,
          owner_id,
          error:
        )
      end
    end

    def supersede_stale_effect(run_id)
      superseded = ct.lifecycle.supersede_stale_effect(run_id)
      release_effect(superseded)
      ct.lifecycle.clear_stale_observer(run_id)
    end

    def reconcile_unlaunched(run_id)
      if ct.lifecycle.desired_state == :running
        ct.lifecycle.cancel_unlaunched(
          run_id,
          'unlaunched lifecycle run deferred until daemon readiness'
        )
        [:start, ct.lifecycle.current_intent_id]
      else
        ct.lifecycle.cancel_unlaunched(
          run_id,
          'unlaunched lifecycle run cancelled during reconciliation'
        )
        nil
      end
    end

    def run_reconciliation_followup(followup)
      action, intent_id = followup
      return if action == :start && !Daemon.get.ready?

      thread = Thread.new do
        command = action == :start ? Commands::Container::Start : Commands::Container::Stop
        opts = {
          pool: ct.pool.name,
          id: ct.id,
          lifecycle_source: 'daemon-restart',
          lifecycle_intent_id: intent_id,
          manipulation_lock: 'wait'
        }
        opts[:method] = 'shutdown_or_kill' if action == :stop
        opts[:lifecycle_recovery] = true
        ret = command.run(**opts)
        unless ret[:status]
          log(
            :info,
            "Deferred #{action} follow-up for #{ct.ident}: #{ret[:message]}"
          )
        end
      rescue CommandFailed => e
        log(:info, "Deferred #{action} follow-up for #{ct.ident}: #{e.message}")
      rescue StandardError => e
        log(
          :warn,
          "Reconciliation #{action} follow-up failed for #{ct.ident}: " \
          "#{e.message} (#{e.class})"
        )
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def replacement_requested?(run)
      launch_intent_id = run['launch_intent_id']
      current_intent_id = ct.lifecycle.current_intent_id

      ct.lifecycle.desired_state == :running \
        && launch_intent_id \
        && current_intent_id \
        && current_intent_id != launch_intent_id
    end

    def exact_run_conf(run_id)
      in_memory = [ct.run_conf, ct.get_past_run_conf].compact.detect do |run_conf|
        run_conf.run_id == run_id
      end
      in_memory || Container::RunConfiguration.load_generation(ct, run_id)
    end

    def generation_identities(root)
      CGroup.get_tree_pids(root).filter_map do |pid|
        ProcessIdentity.capture(pid)
      end
    end

    def generation_process_evidence(root, kills: [])
      delivered = kills.to_h do |kill|
        [[kill.fetch('pid'), kill.fetch('start_time_ticks')], kill['delivered']]
      end

      generation_identities(root).filter_map do |identity|
        next unless identity.alive?
        next unless CGroup.get_tree_pids(root).include?(identity.pid)

        identity.dump.merge(
          'state' => process_state(identity.pid),
          'kill_delivered' => delivered.fetch(
            [identity.pid, identity.start_time_ticks],
            false
          ),
          'fatal_signal_pending' => fatal_signal_pending?(identity.pid)
        )
      end
    end

    def process_state(pid)
      stat = File.read(File.join('/proc', pid.to_s, 'stat'))
      stat[stat.rindex(')') + 2]
    rescue Errno::ENOENT
      nil
    end

    def fatal_signal_pending?(pid)
      status = File.read(File.join('/proc', pid.to_s, 'status'))
      pending = status.each_line.filter_map do |line|
        next unless line.start_with?('SigPnd:', 'ShdPnd:')

        line.split.fetch(1).to_i(16)
      end
      mask = 1 << (Signal.list.fetch('KILL') - 1)
      pending.any? { |value| value.anybits?(mask) }
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end

    def manager_process_evidence(run)
      managers = %w[wrapper lxc_start].filter_map do |name|
        cfg = run[name]
        cfg && [name, cfg]
      end
      managers.concat(
        Array(run['legacy_managers']).map do |cfg|
          [cfg.fetch('kind', 'legacy_manager'), cfg]
        end
      )

      managers.map do |name, cfg|
        identity = ProcessIdentity.load(cfg)
        cfg.merge('kind' => name, 'alive' => identity.alive?)
      end
    end

    def manager_alive?(run)
      return false unless run

      manager_process_evidence(run).any? { |manager| manager['alive'] }
    end

    def manager_identity_ambiguous?(run, managers)
      return false if run['wrapper_gone']
      return false unless %w[launching starting running stopping post_stop cleaning]
                          .include?(run['phase'])

      managers.empty?
    end

    def veth_in_use_by_other_generation?(veth, target_run_id)
      DB::Containers.get.any? do |candidate_ct|
        next true if candidate_ct != ct && candidate_ct.netifs.any? do |netif|
          netif.respond_to?(:veth) && netif.veth == veth
        end

        candidate_ct.lifecycle.runs.values.any? do |run|
          candidate_run_id = load_run_id(run)
          next false if candidate_ct == ct && candidate_run_id == target_run_id
          next false unless %w[active residual].include?(run['role'])

          run.fetch('resources', {})
             .fetch('network_interfaces', {})
             .values
             .any? { |interface| interface['veth'] == veth }
        end
      end
    end

    def container_using_veth(veth)
      DB::Containers.get.detect do |candidate_ct|
        next false if candidate_ct == ct

        candidate_ct.netifs.any? do |netif|
          netif.respond_to?(:veth) && netif.veth == veth
        end
      end
    end

    def remove_veth(veth)
      log(:info, "Removing #{veth}")
      syscmd("ip link delete #{veth}")
      syscmd("ip link delete ifb#{veth}", valid_rcs: [1])
    end

    def finish_clean_recovery(
      run_id,
      recovery_id,
      evidence,
      policy_root_removed: false
    )
      run = ct.lifecycle.run(run_id)

      if run['role'] == 'residual'
        removed = ct.lifecycle.remove_residual(run_id, recovery_id:)
        if removed && policy_root_removed
          ct.lifecycle.clear_policy_taint_after_recovery(
            policy_root_removed: true
          )
        end
      else
        effect, restart_intent_id = ct.lifecycle.recover_clean(
          run_id,
          recovery_id:,
          evidence:
        )
        release_effect(effect)
        detach_run_configuration(run_id)
        if policy_root_removed
          ct.lifecycle.clear_policy_taint_after_recovery(
            policy_root_removed: true
          )
        end
        restart_if_requested(restart_intent_id)
      end
    end

    # Remove and verify the stable policy root in every hierarchy. This is the
    # only filesystem evidence which permits explicit recovery to clear a
    # policy taint without a successful policy reconciliation.
    def cleanup_policy_root(run_id = nil)
      return unless ct.lifecycle.policy_tainted?
      if run_id && ct.lifecycle.other_runtime_generation?(run_id)
        return
      end

      errors = {}
      remaining = []

      CGroup.sync do
        CGroup.subsystems.each do |subsystem|
          CGroup.rmpath(subsystem, ct.base_cgroup_path)
        rescue SystemCallError => e
          errors[subsystem] = "#{e.class}: #{e.message}"
        end

        remaining = CGroup.subsystems.select do |subsystem|
          Dir.exist?(
            CGroup.abs_cgroup_path(
              subsystem,
              ct.base_cgroup_path
            )
          )
        end
      end

      {
        'complete' => remaining.empty?,
        'root' => ct.base_cgroup_path,
        'remaining_subsystems' => remaining,
        'errors' => errors
      }
    end

    def detach_run_configuration(run_id, preserve: false)
      run_conf = exact_run_conf(run_id)
      return unless run_conf

      if preserve
        ct.detach_run_conf(run_conf)
      else
        ct.detach_run_conf(run_conf)
        run_conf.destroy
      end
    end

    def cleanup_generation_artifacts(run_id)
      run_conf = exact_run_conf(run_id)
      errors = []

      if AppArmor.enabled? && run_conf
        begin
          ct.apparmor.destroy_namespace(run_conf)
          ct.apparmor.destroy_profile(run_conf)
        rescue StandardError => e
          errors << "unable to remove generation AppArmor resources: #{e.message}"
        end
      end

      run = ct.lifecycle.run(run_id)
      lxc_config = run&.dig('resources', 'lxc_config')
      if lxc_config
        begin
          File.unlink(lxc_config)
        rescue Errno::ENOENT
          nil
        rescue StandardError => e
          errors << "unable to remove generation LXC configuration: #{e.message}"
        end
      end

      if run_conf
        begin
          ct.lxc_config.remove_run_hooks(run_conf)
          run_conf.destroy
        rescue StandardError => e
          errors << "unable to remove generation runtime resources: #{e.message}"
        end
      end

      errors
    end

    def release_effect(effect)
      return unless effect
      return unless %w[start stop].include?(effect['type'])

      Container::LifecycleExecutor.release(ct.pool, effect['type'].to_sym, effect['id'])
    end

    def restart_if_requested(intent_id)
      return unless intent_id
      return unless Daemon.get.ready?

      thread = Thread.new do
        ret = Commands::Container::Start.run(
          pool: ct.pool.name,
          id: ct.id,
          lifecycle_source: 'recovery',
          lifecycle_intent_id: intent_id,
          lifecycle_recovery: true,
          manipulation_lock: 'wait'
        )
        unless ret[:status]
          log(
            :info,
            "Recovery start for #{ct.ident} was deferred: #{ret[:message]}"
          )
        end
      rescue CommandFailed => e
        log(:info, "Recovery start for #{ct.ident} was deferred: #{e.message}")
      rescue StandardError => e
        log(
          :warn,
          "Recovery start failed for #{ct.ident}: #{e.message} (#{e.class})"
        )
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def result(outcome, run_id, requested:, completed:, evidence:, hazards:,
               active_slot_released: false)
      raise ArgumentError, "invalid recovery outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

      {
        outcome:,
        incarnation_id: ct.incarnation_id,
        run_id: run_id && (run_id.respond_to?(:to_s) ? run_id.to_s : run_id),
        lifecycle_revision: ct.lifecycle.revision,
        requested_cleanup: requested,
        completed_cleanup: completed,
        active_slot_released:,
        residual_run_ids: ct.lifecycle.residuals.map { |run| load_run_id(run).to_s },
        evidence:,
        hazards:
      }
    end

    def load_run_id(run)
      Container::RunId.load(run.fetch('id'))
    end
  end
end
