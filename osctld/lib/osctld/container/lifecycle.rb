require 'fileutils'
require 'securerandom'
require 'libosctl'
require 'osctld/container/run_id'
require 'osctld/process_identity'
require 'osctld/thread_reaper'

module OsCtld
  # Durable, per-container lifecycle reducer.
  #
  # The record is authoritative for lifecycle ownership. Potentially blocking
  # effects are executed by callers outside of {#sync}; their results have to
  # match the recorded effect ID before they can be committed.
  class Container::Lifecycle
    include OsCtl::Lib::Utils::Log

    SCHEMA = 1
    POLICY_WORKER_RECHECK_INTERVAL = 1
    PROCESS_WORKER_RECHECK_INTERVAL = 1
    TAINT_SAFE_CALLBACKS = %w[CtPostStop VethDown].freeze
    TERMINAL_START_PHASES = %w[running clean failed cleanup_failed quarantined].freeze
    FINALIZABLE_PHASES = %w[stopping post_stop cleaning].freeze

    Request = Struct.new(
      :action,
      :run_id,
      :revision,
      :effect_id,
      :intent_id,
      :warning,
      keyword_init: true
    )
    RecoveryLease = Struct.new(
      :id,
      :superseded_effect,
      :blocking_workers,
      :busy,
      keyword_init: true
    )
    PolicyLease = Struct.new(
      :id,
      :revision,
      keyword_init: true
    )
    PolicyCompletion = Struct.new(
      :run_id,
      :effect_id,
      keyword_init: true
    )

    # @param ct [Container]
    def initialize(ct)
      @ct = ct
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @record = load_record || default_record
      validate_record!
    end

    def request_start(source: 'external', expected_intent_id: nil)
      sync do
        if live_policy_update_locked
          next Request.new(
            action: :wait,
            revision:,
            intent_id: current_intent_id_locked
          )
        end

        if effective_policy_tainted_locked?
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: policy_taint_warning_locked
          )
        end

        active = active_run_locked
        changed = false

        if expected_intent_id
          next superseded_request unless current_intent_id_locked == expected_intent_id
        elsif active.nil? \
            || record['desired_state'] != 'running' \
            || (run_ending?(active) && !pending_running_intent?(active))
          update_intent('running', 'start', source)
          changed = true
        end

        if active
          action =
            if active['recovery']
              :wait
            elsif execution_run_locked?(active)
              active['phase'] == 'cleanup_failed' ? :failed : :wait
            else
              case active.fetch('phase')
              when 'running'
                if active['effect'] || pending_running_intent?(active)
                  :wait
                else
                  :running
                end
              when 'preparing'
                if pending_running_intent?(active)
                  :wait
                else
                  active['effect'] ? :join : :launch
                end
              when 'launching', 'starting'
                pending_running_intent?(active) ? :wait : :join
              when 'cleanup_failed'
                :failed
              else
                :wait
              end
            end

          commit if changed
          next Request.new(
            action:,
            run_id: load_run_id(active),
            revision: revision,
            intent_id: current_intent_id_locked,
            warning: residual_warning_locked
          )
        end

        prune_clean_runs
        planned_run = ct.next_run_conf || ct.run_conf
        run_id =
          if planned_run
            planned_run.run_id
          else
            Container::RunId.new(pool_name: ct.pool.name, container_id: ct.id)
          end
        run = {
          'id' => run_id.dump,
          'role' => 'active',
          'kind' => 'container',
          'phase' => 'preparing',
          'created_at' => Time.now.to_f,
          'launch_intent_id' => current_intent_id_locked,
          'observations' => {},
          'resources' => generation_resources(run_id),
          'hazards' => [],
          'post_stop' => false,
          'reported_state' => nil,
          'running_effects_started' => false,
          'running_effects_done' => false,
          'on_stop_hook_started' => false,
          'on_stop_hook_done' => false,
          'post_stop_hook_started' => false,
          'post_stop_hook_done' => false,
          'wrapper_gone' => false,
          'reboot' => false,
          'pre_start_consumed' => false,
          'pre_start_completed' => false,
          'pre_start_callback_id' => nil,
          'lxc_start_authorized' => false,
          'observer' => nil,
          'reconciliation' => nil,
          'callbacks' => {},
          'processes' => {},
          'recovery' => nil,
          'effect' => nil
        }

        record.fetch('runs')[run_id.to_s] = run
        record['active_run_id'] = run_id.to_s
        commit

        Request.new(
          action: :launch,
          run_id:,
          revision:,
          intent_id: current_intent_id_locked,
          warning: residual_warning_locked
        )
      end
    end

    # Admit an lxc-execute operation for a stopped container. The transient
    # generation occupies the same active slot as a normal start, but does not
    # change the container's desired state.
    def request_execution(source: 'external')
      sync do
        if live_policy_update_locked
          next Request.new(
            action: :wait,
            revision:,
            intent_id: current_intent_id_locked
          )
        end

        if effective_policy_tainted_locked?
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: policy_taint_warning_locked
          )
        end

        active = active_run_locked

        if active
          action = :wait
          unless active['recovery']
            action =
              if container_run_locked?(active) \
                  && active['phase'] == 'running' \
                  && active['effect'].nil? \
                  && active['observer'].nil? \
                  && active['reconciliation'].nil? \
                  && record['desired_state'] == 'running' \
                  && current_intent_id_locked == active['launch_intent_id'] \
                  && !pending_running_intent?(active)
                :running
              elsif active['phase'] == 'cleanup_failed'
                :failed
              else
                :wait
              end
          end

          next Request.new(
            action:,
            run_id: load_run_id(active),
            revision:,
            intent_id: current_intent_id_locked,
            warning: residual_warning_locked
          )
        end

        if record.fetch('runs').values.any? { |run| run['role'] == 'residual' }
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: 'stopped execution is blocked by residual container generations'
          )
        end

        prune_clean_runs
        run_id = Container::RunId.new(
          pool_name: ct.pool.name,
          container_id: ct.id
        )
        run = {
          'id' => run_id.dump,
          'role' => 'active',
          'kind' => 'execution',
          'source' => source,
          'phase' => 'preparing',
          'created_at' => Time.now.to_f,
          'launch_intent_id' => current_intent_id_locked,
          'observations' => {},
          'resources' => generation_resources(run_id, kind: 'execution'),
          'hazards' => [],
          'post_stop' => false,
          'reported_state' => nil,
          'running_effects_started' => false,
          'running_effects_done' => false,
          'on_stop_hook_started' => false,
          'on_stop_hook_done' => false,
          'post_stop_hook_started' => false,
          'post_stop_hook_done' => false,
          'wrapper_gone' => false,
          'reboot' => false,
          'pre_start_consumed' => false,
          'pre_start_completed' => false,
          'pre_start_callback_id' => nil,
          'lxc_start_authorized' => false,
          'observer' => nil,
          'reconciliation' => nil,
          'callbacks' => {},
          'processes' => {},
          'recovery' => nil,
          'effect' => nil
        }

        record.fetch('runs')[run_id.to_s] = run
        record['active_run_id'] = run_id.to_s
        commit

        Request.new(
          action: :launch,
          run_id:,
          revision:,
          intent_id: current_intent_id_locked,
          warning: residual_warning_locked
        )
      end
    end

    def request_stop(source: 'external', expected_intent_id: nil)
      sync do
        active = active_run_locked
        changed = false

        if expected_intent_id
          next superseded_request unless current_intent_id_locked == expected_intent_id
        elsif record['desired_state'] != 'stopped' \
            || active.nil? \
            || (
              active \
              && execution_run_locked?(active) \
              && record.dig('intent', 'kind') != 'stop'
            )
          update_intent('stopped', 'stop', source)
          changed = true
        end

        # A persisted direct-reboot reservation has no worker after signal
        # delivery and can otherwise remain forever when its post-stop
        # callback is lost. An explicit stop is the safe operational
        # supersession: it keeps the same generation fenced while asking LXC
        # to stop whichever init instance currently owns it.
        if active&.dig('effect', 'type') == 'control_reboot'
          effect = active.fetch('effect')
          active['hazards'] << \
            "stop superseded pending control reboot effect #{effect['id']}"
          active['effect'] = nil
          changed = true
        end

        if active \
            && active['phase'] == 'preparing' \
            && !active['effect'] \
            && !active['observer'] \
            && !active['recovery']
          active['phase'] = 'clean'
          active['role'] = 'history'
          active['error'] = 'unlaunched start superseded by stop intent'
          record['active_run_id'] = nil
          active = nil
          changed = true
        end
        action =
          if active.nil?
            :stopped
          elsif !active['recovery'] \
              && !active['observer'] \
              && %w[launching starting running].include?(active['phase']) \
              && !active['effect']
            :stop
          else
            :wait
          end
        commit if changed

        Request.new(
          action:,
          run_id: active && load_run_id(active),
          revision:,
          intent_id: current_intent_id_locked
        )
      end
    end

    def request_restart(source: 'external')
      sync do
        if live_policy_update_locked
          next Request.new(
            action: :wait,
            revision:,
            intent_id: current_intent_id_locked
          )
        end

        if effective_policy_tainted_locked?
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: policy_taint_warning_locked
          )
        end

        update_intent('running', 'restart', source)
        active = active_run_locked
        commit

        Request.new(
          action: active ? :stop : :launch,
          run_id: active && load_run_id(active),
          revision:,
          effect_id: current_intent_id_locked,
          intent_id: current_intent_id_locked
        )
      end
    end

    # Reserve a direct liblxc reboot. lxcapi_reboot only delivers a signal and
    # returns, so this effect remains durable until the exact post-stop
    # callback proves that teardown began. The caller retains the container
    # manipulation lock between this decision and signal delivery.
    def request_control_reboot
      sync do
        if live_policy_update_locked
          next Request.new(
            action: :wait,
            revision:,
            intent_id: current_intent_id_locked
          )
        end

        if effective_policy_tainted_locked?
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: policy_taint_warning_locked
          )
        end

        active = active_run_locked
        unless active
          next Request.new(
            action: :blocked,
            revision:,
            intent_id: current_intent_id_locked,
            warning: 'container is not running'
          )
        end

        unless stable_runtime_locked?(active)
          next Request.new(
            action: :wait,
            run_id: load_run_id(active),
            revision:,
            intent_id: current_intent_id_locked
          )
        end

        effect_id = SecureRandom.uuid
        active['effect'] = {
          'id' => effect_id,
          'type' => 'control_reboot',
          'record_revision' => revision + 1,
          'worker' => nil,
          'status' => 'awaiting_post_stop'
        }
        commit

        Request.new(
          action: :ready,
          run_id: load_run_id(active),
          revision:,
          effect_id:,
          intent_id: current_intent_id_locked
        )
      end
    end

    # A failed runner reply cannot prove that liblxc did not already deliver
    # the reboot signal. Keep the reservation until exact post-stop evidence,
    # or until an explicit stop deliberately supersedes it.
    def record_control_reboot_error(run_id, effect_id, error)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('effect', 'id') == effect_id
        return false unless run.dig('effect', 'type') == 'control_reboot'

        run['effect']['status'] = 'delivery_unknown'
        run['effect']['delivery_error'] = error
        run['control_reboot_error'] = error
        commit
        true
      end
    end

    def request_reboot(run_id, source: 'container')
      sync do
        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless container_run_locked?(run)

        run['reboot'] = true
        if record['desired_state'] != 'stopped' && !pending_running_intent?(run)
          update_intent('running', 'reboot', source)
        end
        commit
        true
      end
    end

    def claim_effect(run_id, type, expected_intent_id: nil)
      sync do
        run = require_run_locked(run_id)
        return if expected_intent_id && current_intent_id_locked != expected_intent_id
        return unless active_run_locked.equal?(run)
        return if live_policy_update_locked
        return if effective_policy_tainted_locked? && type.to_sym != :stop
        return if run['recovery'] || run['observer'] || run['reconciliation']
        return if type.to_sym != :stop && live_workers_locked(run).any?

        current = run['effect']
        return if current

        effect_id = SecureRandom.uuid
        run.delete('stop_error') if type.to_sym == :stop
        run['effect'] = {
          'id' => effect_id,
          'type' => type.to_s,
          'record_revision' => revision + 1,
          'worker' => nil,
          'status' => 'claimed'
        }
        commit
        effect_id
      end
    end

    def set_effect_worker(run_id, effect_id, pid)
      identity =
        if pid.to_i == Process.pid
          ProcessIdentity.capture_thread
        else
          ProcessIdentity.capture(pid)
        end

      sync do
        effect = require_effect_locked(run_id, effect_id)
        return false unless effect

        effect['worker'] = identity&.dump
        effect['status'] = 'running'
        commit
        true
      end
    end

    def effect_current?(run_id, effect_id)
      sync do
        run = find_run_locked(run_id)
        run \
          && !run['recovery'] \
          && run.dig('effect', 'id') == effect_id
      end
    end

    # Publish the end of the exact Ruby worker. Native thread IDs can remain
    # present after a Ruby Thread exits, so recovery must not infer this
    # boundary solely from /proc while osctld is still running.
    def effect_worker_exited(run_id, effect_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run

        effect = run['effect']
        return false unless effect && effect['id'] == effect_id

        effect['worker'] = nil
        effect['status'] = 'worker_exited'
        commit
        true
      end
    end

    def finish_effect(run_id, effect_id)
      sync do
        effect = require_effect_locked(run_id, effect_id)
        return false unless effect

        run = require_run_locked(run_id)
        if %w[start execute].include?(effect['type']) \
            && !run.fetch('pre_start_completed', false)
          wrapper = run['wrapper'] && ProcessIdentity.load(run['wrapper'])
          return false if wrapper&.alive? && !run['wrapper_gone']
        end

        run['effect'] = nil
        commit
        true
      end
    end

    def claim_finalization(run_id)
      sync do
        run = find_run_locked(run_id)
        run && claim_finalize_locked(run)
      end
    end

    # Supersede only an effect whose exact worker is absent. The worker check
    # and effect removal share the reducer lock with worker publication.
    def supersede_stale_effect(run_id)
      sync do
        run = require_run_locked(run_id)
        return if run['recovery']

        effect = run['effect']
        return unless effect
        return if effect['type'] == 'control_reboot'

        if effect['worker']
          worker = ProcessIdentity.load(effect['worker'])
          return if worker.alive?
        end

        run['effect'] = nil
        run['hazards'] << "superseded #{effect['type']} effect #{effect['id']}"
        commit
        deep_copy(effect)
      end
    end

    def clear_stale_observer(run_id)
      sync do
        run = require_run_locked(run_id)
        return false if run['recovery']

        observer = run['observer']
        return true unless observer

        if observer['worker']
          worker = ProcessIdentity.load(observer['worker'])
          return false if worker.alive?
        end

        run['observer'] = nil
        commit
        true
      end
    end

    def mark_launching(run_id, effect_id, wrapper_pid)
      identity = ProcessIdentity.capture(wrapper_pid)
      return false unless identity

      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false unless run.dig('effect', 'type') == 'start'
        return false unless container_run_locked?(run)

        run['phase'] = 'launching'
        run['wrapper'] = identity.dump
        commit
        true
      end
    end

    # Publish the exact osctld-created runner which is allowed to launch one
    # stopped-container lxc-execute process.
    def mark_execution_launching(run_id, effect_id, runner_pid)
      identity = ProcessIdentity.capture(runner_pid)
      return false unless identity

      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false unless execution_run_locked?(run)
        return false unless run.dig('effect', 'type') == 'execute'

        run['phase'] = 'launching'
        run['wrapper'] = identity.dump
        commit
        true
      end
    end

    # Reserve launch authorization for an osctld-ct-start process descended
    # from the exact wrapper published by the start effect.
    def authorize_lxc_start(run_id, pid)
      identity = ProcessIdentity.capture(pid)
      return false unless identity

      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false unless container_run_locked?(run)
        return false unless run['phase'] == 'launching'
        return false if run['recovery']
        return false unless run.dig('effect', 'type') == 'start'
        return false if run['lxc_start']

        wrapper_cfg = run['wrapper']
        return false unless wrapper_cfg

        wrapper = ProcessIdentity.load(wrapper_cfg)
        return false unless wrapper.alive?
        return false unless wrapper.ancestor_of?(pid)

        run['lxc_start'] = identity.dump
        run['lxc_start_authorized'] = false
        commit
        true
      end
    end

    # Reserve launch authorization for an lxc-execute process descended from
    # the exact stopped-container runner.
    def authorize_lxc_execution(run_id, pid)
      identity = ProcessIdentity.capture(pid)
      return false unless identity

      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false unless execution_run_locked?(run)
        return false unless run['phase'] == 'launching'
        return false if run['recovery']
        return false unless run.dig('effect', 'type') == 'execute'
        return false if run['lxc_start']

        runner_cfg = run['wrapper']
        return false unless runner_cfg

        runner = ProcessIdentity.load(runner_cfg)
        return false unless runner.alive?
        return false unless runner.ancestor_of?(pid)

        run['lxc_start'] = identity.dump
        run['lxc_start_authorized'] = false
        commit
        true
      end
    end

    # Finish osctld-ct-start setup after its cgroup and OOM state are ready.
    def activate_lxc_start(run_id, pid)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless %w[start execute].include?(run.dig('effect', 'type'))
        return false unless run['lxc_start']

        identity = ProcessIdentity.load(run['lxc_start'])
        return false unless identity.alive?
        return false unless identity.pid == pid.to_i

        run['lxc_start_authorized'] = true
        run['phase'] = 'starting'
        commit
        true
      end
    end

    def consume_pre_start(run_id, client_pid:, callback_id:)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless run['lxc_start']
        return false unless run['lxc_start_authorized']
        return false if run['pre_start_consumed']

        identity = ProcessIdentity.load(run['lxc_start'])
        return false unless identity.alive?
        return false unless identity.ancestor_of?(client_pid)

        callback = run.fetch('callbacks', {})[callback_id]
        return false unless callback
        return false unless callback['name'] == 'CtPreStart'
        return false unless callback['status'] == 'running'

        run['pre_start_consumed'] = true
        run['pre_start_callback_id'] = callback_id
        commit
        true
      end
    end

    # Publish the first boundary which proves that the authorized process has
    # exec'd into LXC and that LXC's exact pre-start hook has completed all
    # privileged generation setup. Wrapper authorization alone is deliberately
    # insufficient: after that callback returns, the wrapper still has to exec
    # lxc-start/lxc-execute and could otherwise recreate runtime after a stop.
    #
    # The launch effect is released atomically with this marker for both normal
    # starts and stopped-container executions. From this point onward, stop is
    # allowed to take over because LXC already owns the exact runtime. The
    # wrapper and callback identities remain generation workers, so post-stop
    # cleanup still cannot overtake either one.
    def complete_pre_start(run_id, callback_id:)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless run['pre_start_consumed']
        return false if run.fetch('pre_start_completed', false)
        return false unless run['pre_start_callback_id'] == callback_id

        callback = run.fetch('callbacks', {})[callback_id]
        return false unless callback
        return false unless callback['name'] == 'CtPreStart'
        return false unless callback['status'] == 'running'

        effect = run['effect']
        expected_type = execution_run_locked?(run) ? 'execute' : 'start'
        return false unless effect && effect['type'] == expected_type

        run['pre_start_completed'] = true
        run['effect'] = nil
        commit
        [true, effect['id']]
      end
    end

    def observe_state(run_id, state, init_pid: nil, source: 'monitor')
      sync do
        run = find_run_locked(run_id)
        return false unless run

        run['observations'][source] = {
          'state' => state.to_s,
          'init_pid' => init_pid,
          'at' => Time.now.to_f,
          'record_revision' => revision + 1
        }

        if !active_run_locked.equal?(run) \
            || run['recovery'] \
            || %w[quarantined clean].include?(run['phase'])
          commit
          return false
        end

        apply_state_observation_locked(run, state, init_pid:)

        commit
        true
      end
    end

    # Claim ownership of monitor side effects for an exact run. Recovery
    # cannot release the active slot while this worker is alive.
    def begin_state_observation(run_id, state, init_pid: nil, source: 'monitor')
      identity = ProcessIdentity.capture_thread
      return unless identity

      sync do
        run = find_run_locked(run_id)
        return unless run

        policy_update = live_policy_update_locked
        clear_stale_reconciliation_locked(run)
        run['observations'][source] = {
          'state' => state.to_s,
          'init_pid' => init_pid,
          'at' => Time.now.to_f,
          'record_revision' => revision + 1
        }

        if policy_update \
            || effective_policy_tainted_locked? \
            || !active_run_locked.equal?(run) \
            || run['recovery'] \
            || run['reconciliation'] \
            || run['observer'] \
            || run.dig('effect', 'type') == 'cleanup' \
            || %w[quarantined clean].include?(run['phase'])
          commit
          return
        end

        observer_id = SecureRandom.uuid
        run['observer'] = {
          'id' => observer_id,
          'worker' => identity.dump,
          'state' => state.to_s,
          'source' => source,
          'record_revision' => revision + 1
        }
        apply_state_observation_locked(run, state, init_pid:)
        commit
        observer_id
      end
    end

    def state_observation_current?(run_id, observer_id)
      sync do
        run = find_run_locked(run_id)
        run \
          && !run['recovery'] \
          && run.dig('observer', 'id') == observer_id
      end
    end

    def finish_state_observation(run_id, observer_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('observer', 'id') == observer_id

        run['observer'] = nil
        commit
        claim_finalize_locked(run)
      end
    end

    # Claim externally visible state effects for a verified observation. The
    # last published state is stored per generation, so a delayed name-only
    # lxc-monitor line can at most reconcile the current generation once.
    def claim_state_effects(run_id, observer_id, state)
      sync do
        run = find_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false unless run.dig('observer', 'id') == observer_id
        return false if run['recovery']

        claim_state_effects_locked(run, state)
      end
    end

    # Claim startup state effects while holding an exclusive reconciliation
    # lease. This resumes an unclaimed RUNNING publication after daemon
    # restart without relying on another lxc-monitor transition.
    def claim_reconciliation_state_effects(run_id, reconciliation_id, state)
      sync do
        run = find_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false unless run.dig('reconciliation', 'id') == reconciliation_id
        return false unless run.dig('reconciliation', 'exclusive')
        return false if run['recovery']
        return false if effective_policy_tainted_locked?

        claim_state_effects_locked(run, state)
      end
    end

    def complete_running_effects(run_id, owner_id, error: nil)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('observer', 'id') == owner_id \
                            || run.dig('reconciliation', 'id') == owner_id

        run['running_effects_done'] = true
        run['running_effects_error'] = error if error
        commit
        true
      end
    end

    # Lease exact-generation reconciliation performed outside the reducer.
    # Cleanup waits for this worker, while a recovery fence prevents it from
    # starting in the first place.
    def begin_reconciliation(run_id, source:)
      identity = ProcessIdentity.capture_thread
      return unless identity

      sync do
        run = find_run_locked(run_id)
        return unless active_run_locked.equal?(run)
        return if run['recovery']
        return if live_policy_update_locked
        return if effective_policy_tainted_locked? \
                  && source.to_s != 'state_recovery'

        clear_stale_reconciliation_locked(run)
        return if run['reconciliation']

        live = live_workers_locked(run)
        return if live.any?

        worker_conflict = %w[effect observer].any? do |worker_type|
          worker = run.dig(worker_type, 'worker')
          next false unless worker

          owner = ProcessIdentity.load(worker)
          owner.alive? && owner.dump != identity.dump
        end
        return if worker_conflict

        reconciliation_id = SecureRandom.uuid
        run['reconciliation'] = {
          'id' => reconciliation_id,
          'worker' => identity.dump,
          'source' => source,
          'exclusive' => false,
          'yield_requested' => false,
          'record_revision' => revision + 1
        }
        commit
        reconciliation_id
      end
    end

    # Commit the point after which callbacks have to wait for reconciliation.
    # An exact callback which arrived first requests that reconciliation yield
    # before it performs any externally visible state effects.
    def commit_reconciliation(run_id, reconciliation_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run

        reconciliation = run['reconciliation']
        return false unless reconciliation&.fetch('id') == reconciliation_id
        return true if reconciliation['exclusive']
        return false if reconciliation['yield_requested']

        reconciliation['exclusive'] = true
        commit
        true
      end
    end

    def finish_reconciliation(run_id, reconciliation_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('reconciliation', 'id') == reconciliation_id

        run['reconciliation'] = nil
        commit
        claim_finalize_locked(run)
      end
    end

    # User-control callbacks execute privileged generation effects in osctld
    # threads. Persist their exact worker identities so recovery cannot race
    # them while the daemon remains alive.
    def begin_callback(run_id, name:)
      identity = ProcessIdentity.capture_thread
      return unless identity

      sync do
        run = find_run_locked(run_id)
        return unless active_run_locked.equal?(run)
        return if run['recovery']
        return if run.dig('effect', 'type') == 'cleanup'
        return if policy_taint_blocks_callback_locked?(name)

        callback_id = SecureRandom.uuid
        run['callbacks'] ||= {}
        run['callbacks'][callback_id] = {
          'id' => callback_id,
          'name' => name.to_s,
          'worker' => identity.dump,
          'status' => 'waiting',
          'record_revision' => revision + 1
        }
        commit

        while live_policy_update_locked
          if daemon_stopping?
            run.fetch('callbacks', {}).delete(callback_id)
            commit
            return
          end

          @cv.wait(@mutex, POLICY_WORKER_RECHECK_INTERVAL)
          run = find_run_locked(run_id)
          return unless run

          next if active_run_locked.equal?(run) \
              && !run['recovery'] \
              && run.dig('effect', 'type') != 'cleanup'

          run.fetch('callbacks', {}).delete(callback_id)
          commit
          return
        end

        if policy_taint_blocks_callback_locked?(name)
          run.fetch('callbacks', {}).delete(callback_id)
          commit
          return
        end

        clear_stale_reconciliation_locked(run)
        reconciliation = run['reconciliation']
        if reconciliation && !reconciliation['exclusive']
          reconciliation['yield_requested'] = true
          run['callbacks'][callback_id]['status'] = 'running'
          commit
          return callback_id
        end

        unless reconciliation
          run['callbacks'][callback_id]['status'] = 'running'
          commit
          return callback_id
        end

        commit

        loop do
          run = find_run_locked(run_id)
          return unless run
          return unless active_run_locked.equal?(run)
          return if run['recovery']
          return if run.dig('effect', 'type') == 'cleanup'
          break unless run['reconciliation']
          return if daemon_stopping?

          @cv.wait(@mutex)
        end

        callback = run.fetch('callbacks', {})[callback_id]
        return unless callback

        callback['status'] = 'running'
        commit
        callback_id
      end
    end

    def finish_callback(run_id, callback_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.fetch('callbacks', {}).delete(callback_id)

        commit
        claim_finalize_locked(run)
      end
    end

    # Persist hook child identities. Hook children are also placed in the
    # generation cgroup, which covers descendants that outlive their parent.
    def register_process(run_id, kind:, pid:)
      identity = ProcessIdentity.capture(pid)
      return unless identity

      process_id = sync do
        run = find_run_locked(run_id)
        return unless active_run_locked.equal?(run)
        return if live_policy_update_locked
        return if run['recovery']
        return unless identity.alive?

        process_id = SecureRandom.uuid
        run['processes'] ||= {}
        run['processes'][process_id] = {
          'id' => process_id,
          'kind' => kind.to_s,
          'identity' => identity.dump,
          'record_revision' => revision + 1
        }
        commit
        process_id
      end
      watch_process(run_id, process_id) if process_id
      process_id
    end

    # Admit a runner which attaches to an already running normal container.
    # The exact identity remains a generation worker until the frontend reaps
    # it, so stop cleanup cannot overtake an accepted attachment.
    def register_attachment(run_id, pid:)
      identity = ProcessIdentity.capture(pid)
      return unless identity

      process_id = sync do
        run = find_run_locked(run_id)
        return unless run
        return unless active_run_locked.equal?(run)
        return unless container_run_locked?(run)
        return unless run['phase'] == 'running'
        return if live_policy_update_locked || effective_policy_tainted_locked?
        return if run['recovery']
        return if run['effect']
        return unless record['desired_state'] == 'running'
        return unless current_intent_id_locked == run['launch_intent_id']
        return unless identity.alive?

        process_id = SecureRandom.uuid
        run['processes'] ||= {}
        run['processes'][process_id] = {
          'id' => process_id,
          'kind' => 'attachment',
          'identity' => identity.dump,
          'record_revision' => revision + 1
        }
        commit
        process_id
      end
      watch_process(run_id, process_id) if process_id
      process_id
    end

    # Transfer an external attachment reservation from the management client
    # to its gated osctld-ct-exec child before that child creates or enters
    # container cgroups.
    def handoff_attachment(run_id, process_id, pid:)
      identity = ProcessIdentity.capture(pid)
      return false unless identity

      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery'] || live_policy_update_locked

        process = run.fetch('processes', {})[process_id]
        return false unless process
        return false unless process['kind'] == 'attachment'

        owner = ProcessIdentity.load(process.fetch('identity'))
        return false unless owner.ancestor_of?(pid)
        return false unless identity.alive?

        process['identity'] = identity.dump
        process['supervisor'] = identity.dump
        process['external_stage'] = 'wrapper'
        process['record_revision'] = revision + 1
        commit
        true
      end
    end

    # Transfer the external wrapper's reservation to the gated command child.
    # The wrapper remains the only process allowed to finish the reservation,
    # while liveness follows the child that can enter or change container
    # cgroups.
    def handoff_attachment_child(run_id, process_id, pid:, child_pid:)
      identity = ProcessIdentity.capture(pid)
      child = ProcessIdentity.capture(child_pid)
      return false unless identity && child

      sync do
        run = find_run_locked(run_id)
        return false unless run

        process = run.fetch('processes', {})[process_id]
        return false unless process
        return false unless process['kind'] == 'attachment'
        return false unless process['external_stage'] == 'wrapper'
        return false unless process.fetch('identity') == identity.dump
        return false unless process.fetch('supervisor') == identity.dump
        return false unless identity.ancestor_of?(child_pid)
        return false unless child.alive?

        process['identity'] = child.dump
        process['external_stage'] = 'child'
        process['record_revision'] = revision + 1
        commit
        true
      end
    end

    # Finish an external attachment only from the exact process which accepted
    # its reservation. Once ownership follows a command child, its exact
    # supervisor can finish only after the child has exited. Internal frontends
    # use finish_process directly.
    def finish_external_attachment(run_id, process_id, pid:)
      identity = ProcessIdentity.capture(pid)
      return false unless identity

      sync do
        run = find_run_locked(run_id)
        return false unless run

        process = run.fetch('processes', {})[process_id]
        return false unless process
        return false unless process['kind'] == 'attachment'

        case process['external_stage']
        when 'wrapper'
          return false unless process.fetch('identity') == identity.dump
        when 'child'
          return false unless process.fetch('supervisor') == identity.dump
          return false if ProcessIdentity.load(
            process.fetch('identity')
          ).alive?
        else
          return false
        end

        run.fetch('processes').delete(process_id)
        commit
        [true, claim_finalize_locked(run)]
      end
    end

    def finish_process(run_id, process_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.fetch('processes', {}).delete(process_id)

        commit
        claim_finalize_locked(run)
      end
    end

    # Fence an exact run before exceptional cleanup. Once installed, no
    # effect, monitor observation or managed launch can publish more work.
    # A live worker keeps ownership and makes recovery explicitly blocked.
    def begin_recovery(run_id)
      worker = ProcessIdentity.capture_thread
      raise 'unable to identify recovery worker' unless worker

      sync do
        policy_update = live_policy_update_locked
        if policy_update
          return RecoveryLease.new(
            id: policy_update.fetch('id'),
            superseded_effect: nil,
            blocking_workers: [
              policy_update.merge('kind' => 'policy_update')
            ],
            busy: true
          )
        end

        run = require_run_locked(run_id)
        current = run['recovery']
        if current && current['worker']
          current_worker = ProcessIdentity.load(current.fetch('worker'))
          if current_worker.alive? && current_worker.dump != worker.dump
            return RecoveryLease.new(
              id: current.fetch('id'),
              superseded_effect: nil,
              blocking_workers: [current.merge('kind' => 'recovery')],
              busy: true
            )
          end
        end

        recovery_id = SecureRandom.uuid
        run['recovery'] = {
          'id' => recovery_id,
          'worker' => worker.dump,
          'record_revision' => revision + 1,
          'started_at' => Time.now.to_f
        }

        blocking_workers = %w[effect observer reconciliation].filter_map do |kind|
          value = run[kind]
          next unless value && value['worker']

          identity = ProcessIdentity.load(value['worker'])
          next unless identity.alive?

          value.merge('kind' => kind)
        end
        blocking_workers.concat(live_workers_locked(run))

        superseded_effect = nil
        if blocking_workers.empty?
          superseded_effect = run['effect']
          if superseded_effect
            run['hazards'] << \
              "recovery superseded #{superseded_effect['type']} effect " \
              "#{superseded_effect['id']}"
          end
          run['effect'] = nil
          run['observer'] = nil
          run['reconciliation'] = nil
        end

        commit
        RecoveryLease.new(
          id: recovery_id,
          superseded_effect: superseded_effect && deep_copy(superseded_effect),
          blocking_workers: deep_copy(blocking_workers),
          busy: false
        )
      end
    end

    def end_recovery(run_id, recovery_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('recovery', 'id') == recovery_id

        run['recovery'] = nil
        commit
        true
      end
    end

    # Retain the fence after a blocked recovery without tying it to a command
    # handler thread which may remain alive for later requests.
    def park_recovery(run_id, recovery_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless run.dig('recovery', 'id') == recovery_id
        return true unless run['recovery']['worker']

        run['recovery']['worker'] = nil
        run['recovery']['parked_at'] = Time.now.to_f
        commit
        true
      end
    end

    def observe_post_stop(run_id, aborted: false, reboot: false)
      sync do
        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']

        control_reboot =
          run.dig('effect', 'type') == 'control_reboot'
        reboot ||= control_reboot
        run['effect'] = nil if control_reboot
        run['post_stop'] = true
        run['aborted'] = aborted
        if container_run_locked?(run)
          run['reboot'] = true if reboot
          if reboot
            if record['desired_state'] != 'stopped' && !pending_running_intent?(run)
              update_intent('running', 'reboot', 'container')
            end
          elsif current_intent_id_locked == run['launch_intent_id']
            update_intent('stopped', 'halt', 'container')
          end
        end
        run['phase'] = 'post_stop'
        commit
        claim_finalize_locked(run)
      end
    end

    def observe_wrapper_gone(run_id)
      sync do
        run = find_run_locked(run_id)
        return false unless run

        run['wrapper_gone'] = true
        run['wrapper'] = nil
        run['lxc_start'] = nil
        run['legacy_managers'] = []
        run['lxc_start_authorized'] = false
        commit
        return false if run['recovery']

        claim_finalize_locked(run)
      end
    end

    def fail_launch(run_id, effect_id, message)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        run['phase'] = 'failed'
        run['role'] = 'history'
        run['error'] = message
        run['effect'] = nil
        record['active_run_id'] = nil if active_run_locked.equal?(run)
        if container_run_locked?(run) && !pending_running_intent?(run)
          update_intent('stopped', 'start_failed', 'lifecycle')
        end
        commit
        true
      end
    end

    def fail_stop(run_id, effect_id, message)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        run['effect'] = nil
        run['stop_error'] = message
        if run['phase'] == 'running' && container_run_locked?(run)
          if record['desired_state'] == 'stopped'
            update_intent('running', 'stop_failed', 'lifecycle')
          end
          run['launch_intent_id'] = current_intent_id_locked
        end
        commit
        true
      end
    end

    def fail_cleanup(run_id, effect_id, message)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        run['phase'] = 'cleanup_failed'
        run['effect'] = nil
        run['error'] = message
        commit
        true
      end
    end

    def claim_finalizer_hook(run_id, effect_id, name)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        key = "#{name}_hook_started"
        return false if run.fetch(key, false)

        run[key] = true
        commit
        true
      end
    end

    def complete_finalizer_hook(run_id, effect_id, name, error: nil)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        return false unless run.fetch("#{name}_hook_started", false)

        run["#{name}_hook_done"] = true
        run["#{name}_hook_error"] = error if error
        commit
        true
      end
    end

    def complete_post_stop_hook(run_id, effect_id, error: nil)
      complete_finalizer_hook(
        run_id,
        effect_id,
        'post_stop',
        error:
      )
    end

    def cancel_unlaunched(run_id, message)
      sync do
        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false unless run['phase'] == 'preparing'
        return false if run['effect']

        run['phase'] = 'clean'
        run['role'] = 'history'
        run['error'] = message
        record['active_run_id'] = nil
        commit
        true
      end
    end

    # Complete post-stop cleanup.
    #
    # @return [Array(Boolean, String), false] completion status and optional
    #   intent ID requesting a new start
    def complete_run(run_id, effect_id)
      sync do
        return false unless require_effect_locked(run_id, effect_id)

        run = require_run_locked(run_id)
        if live_workers_locked(run).any?
          raise 'generation workers remain during lifecycle completion'
        end

        run['phase'] = 'clean'
        run['role'] = 'history'
        run['effect'] = nil
        record['active_run_id'] = nil if active_run_locked.equal?(run)
        restart_intent_id = restart_intent_id_locked(run)
        commit
        [true, restart_intent_id]
      end
    end

    # Move an unclean run out of the active slot.
    #
    # Validation is performed by Container::Recovery immediately before this
    # reducer commit. The supplied evidence is retained for operators.
    def quarantine(run_id, recovery_id:, evidence:, hazards:)
      sync do
        run = require_run_locked(run_id)
        return false unless run.dig('recovery', 'id') == recovery_id

        was_active = active_run_locked.equal?(run)
        run['phase'] = 'quarantined'
        run['role'] = 'residual'
        run['residual_evidence'] = evidence
        run['hazards'] = (run['hazards'] + hazards).uniq
        effect = run['effect']
        run['effect'] = nil
        run['observer'] = nil
        run['recovery'] = nil
        record['active_run_id'] = nil if was_active
        restart_intent_id =
          was_active ? restart_intent_id_locked(run) : nil
        if was_active && !restart_intent_id
          update_intent('stopped', 'recovered', 'recovery')
        end
        commit
        [effect, restart_intent_id]
      end
    end

    def recover_clean(run_id, recovery_id:, evidence:)
      sync do
        run = require_run_locked(run_id)
        return false unless run.dig('recovery', 'id') == recovery_id

        effect = run['effect']
        run['phase'] = 'clean'
        run['role'] = 'history'
        run['effect'] = nil
        run['observer'] = nil
        run['recovery'] = nil
        run['recovery_evidence'] = evidence
        record['active_run_id'] = nil if active_run_locked.equal?(run)
        restart_intent_id = restart_intent_id_locked(run)
        update_intent('stopped', 'recovered', 'recovery') unless restart_intent_id
        commit
        [effect, restart_intent_id]
      end
    end

    def record_resources(run_id, resources, effect_id:, intent_id:)
      sync do
        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless run.dig('effect', 'id') == effect_id
        return false unless execution_run_locked?(run) \
                            || current_intent_id_locked == intent_id

        run['resources'].update(resources.transform_keys(&:to_s))
        commit
        true
      end
    end

    def record_network_interface(
      run_id,
      name:,
      type:,
      veth:,
      routes:,
      callback_id: nil
    )
      callback_worker = ProcessIdentity.capture_thread

      sync do
        run = require_run_locked(run_id)
        return false unless active_run_locked.equal?(run)

        if run['recovery']
          callback = run.fetch('callbacks', {})[callback_id]
          return false unless callback
          return false unless callback['name'] == 'VethUp'
          return false unless callback['status'] == 'running'
          return false unless callback_worker
          return false unless callback['worker'] == callback_worker.dump
        end

        interfaces = run['resources']['network_interfaces'] ||= {}
        interfaces[name] = {
          'type' => type.to_s,
          'veth' => veth,
          'routes' => routes
        }
        commit
        true
      end
    end

    def record_partial_recovery(run_id, recovery_id:, evidence:, hazards:)
      sync do
        run = require_run_locked(run_id)
        return false unless run.dig('recovery', 'id') == recovery_id

        run['recovery_evidence'] = evidence
        run['hazards'] = (run['hazards'] + hazards).uniq
        commit
        true
      end
    end

    def remove_residual(run_id, recovery_id:)
      sync do
        run = require_run_locked(run_id)
        return false unless run['role'] == 'residual'
        return false unless run.dig('recovery', 'id') == recovery_id

        record.fetch('runs').delete(run_key(run_id))
        commit
        true
      end
    end

    def wait_for_change(record_revision, timeout: nil)
      deadline = timeout && (monotonic_now + timeout)

      sync do
        while revision <= record_revision
          return :shutdown if daemon_stopping?

          live_policy_update_locked if record['policy_update']
          break if revision > record_revision

          if deadline
            remaining = deadline - monotonic_now
            return false if remaining <= 0

            wait_for =
              if record['policy_update']
                [remaining, POLICY_WORKER_RECHECK_INTERVAL].min
              else
                remaining
              end
            @cv.wait(@mutex, wait_for)
          elsif record['policy_update']
            @cv.wait(@mutex, POLICY_WORKER_RECHECK_INTERVAL)
          else
            @cv.wait(@mutex)
          end
        end

        true
      end
    end

    def wait_for_start(run_id, timeout: nil)
      deadline = timeout && (monotonic_now + timeout)

      sync do
        loop do
          run = find_run_locked(run_id)
          return :gone unless run

          phase = run.fetch('phase')
          return phase.to_sym if TERMINAL_START_PHASES.include?(phase)
          return :shutdown if daemon_stopping?

          if deadline
            remaining = deadline - monotonic_now
            return :timeout if remaining <= 0

            @cv.wait(@mutex, remaining)
          else
            @cv.wait(@mutex)
          end
        end
      end
    end

    def wait_for_launch_handoff(run_id, effect_id)
      sync do
        loop do
          run = find_run_locked(run_id)
          return :superseded unless run
          return :complete if run.fetch('pre_start_completed', false)
          return :superseded if run['recovery']
          return :superseded unless run.dig('effect', 'id') == effect_id
          return :wrapper_gone if run['wrapper_gone']
          return :shutdown if daemon_stopping?

          @cv.wait(@mutex)
        end
      end
    end

    def wait_for_stop(run_id)
      sync do
        loop do
          run = find_run_locked(run_id)
          return :clean unless run

          phase = run.fetch('phase')
          return phase.to_sym \
            if %w[clean quarantined failed cleanup_failed].include?(phase)
          return :stop_failed if run['stop_error']
          return :shutdown if daemon_stopping?

          @cv.wait(@mutex)
        end
      end
    end

    def wake_all
      sync { @cv.broadcast }
    end

    def active_run_id
      sync do
        active = active_run_locked
        active && load_run_id(active)
      end
    end

    # Old LXC hook configurations do not identify their run. Accept such a
    # callback only while the exact active run was explicitly adopted from a
    # legacy daemon. Callers still have to acquire a callback lease for the
    # returned generation before performing any work.
    def adopted_legacy_callback_run_id
      sync do
        active = active_run_locked
        next unless active&.fetch('legacy_callbacks', false)

        load_run_id(active)
      end
    end

    def active_phase
      sync { active_run_locked&.fetch('phase')&.to_sym }
    end

    def active_run
      sync do
        active = active_run_locked
        active && deep_copy(active)
      end
    end

    def execution_run?(run_id)
      sync do
        run = find_run_locked(run_id)
        run && execution_run_locked?(run)
      end
    end

    def run(run_id)
      sync do
        value = find_run_locked(run_id)
        value && deep_copy(value)
      end
    end

    def runs
      sync { deep_copy(record.fetch('runs')) }
    end

    def residuals
      sync do
        record.fetch('runs').values
              .select { |run| run['role'] == 'residual' }
              .map { |run| deep_copy(run) }
      end
    end

    def runtime_generations
      sync do
        record.fetch('runs').values
              .select { |run| %w[active residual].include?(run['role']) }
              .map { |run| deep_copy(run) }
      end
    end

    def other_runtime_generation?(run_id)
      sync do
        record.fetch('runs').values.any? do |run|
          load_run_id(run) != run_id \
            && %w[active residual].include?(run['role'])
        end
      end
    end

    def desired_state
      sync { record.fetch('desired_state').to_sym }
    end

    def current_intent_id
      sync { current_intent_id_locked }
    end

    # Fence the runtime cgroup topology while container-wide policy is being
    # changed. Lifecycle effects remain outside the reducer, but exact
    # generation cleanup cannot be claimed until this lease is released.
    def begin_policy_update(kind:)
      worker = ProcessIdentity.capture_thread
      return unless worker

      sync do
        return if live_policy_update_locked
        return if inherited_group_policy_state_locked

        active = active_run_locked
        return if active && !stable_runtime_locked?(active)
        return if record.fetch('runs').values.any? { |run| run['recovery'] }

        lease_id = SecureRandom.uuid
        record['policy_update'] = {
          'id' => lease_id,
          'kind' => kind.to_s,
          'worker' => worker.dump,
          'started_at' => Time.now.to_f,
          'record_revision' => revision + 1,
          'started_tainted' => policy_tainted_locked?
        }
        commit

        PolicyLease.new(id: lease_id, revision:)
      end
    end

    # Fence a parent-group policy write across this container. Unlike a
    # container policy reconciliation, this lease cannot repair or clear
    # taint and is admitted only when no residual or recovery state exists.
    def begin_parent_policy_update(kind:, allow_residuals: false)
      worker = ProcessIdentity.capture_thread
      return unless worker

      sync do
        return if live_policy_update_locked
        return if policy_tainted_locked?
        return if record.fetch('runs').values.any? do |run|
          (!allow_residuals && run['role'] == 'residual') || run['recovery']
        end

        active = active_run_locked
        return if active && !stable_runtime_locked?(active)

        lease_id = SecureRandom.uuid
        record['policy_update'] = {
          'id' => lease_id,
          'kind' => kind.to_s,
          'scope' => 'parent',
          'worker' => worker.dump,
          'started_at' => Time.now.to_f,
          'record_revision' => revision + 1,
          'started_tainted' => false
        }
        commit

        PolicyLease.new(id: lease_id, revision:)
      end
    end

    def policy_update_current?(lease_id)
      sync { record.dig('policy_update', 'id') == lease_id }
    end

    def policy_tainted?
      sync do
        live_policy_update_locked
        policy_tainted_locked?
      end
    end

    # Quarantine policy state when reconciliation could not acquire a topology
    # lease. A live worker retains its lease, but the hazard is appended to its
    # durable record and must be carried into the worker's final policy state.
    # Existing taint evidence is retained.
    def record_policy_hazard(kind:, target:, error:, rollback_error:)
      sync do
        evidence = {
          'kind' => kind.to_s,
          'at' => Time.now.to_f,
          'target' => target,
          'error' => error,
          'rollback_error' => rollback_error
        }
        update = live_policy_update_locked
        if update
          update['pending_hazards'] ||= []
          update['pending_hazards'] << evidence
          commit
          next true
        end

        policy_revision = revision + 1
        if policy_tainted_locked?
          record['policy']['pending_hazards'] ||= []
          record['policy']['pending_hazards'] << evidence
          record['policy']['last_reconciliation'] = evidence
          record['policy']['record_revision'] = policy_revision
        else
          record['policy'] = {
            'kind' => kind.to_s,
            'target' => target,
            'applied_at' => evidence.fetch('at'),
            'record_revision' => policy_revision,
            'error' => error,
            'rollback_error' => rollback_error,
            'tainted' => true,
            'pending_hazards' => [evidence]
          }
        end
        commit
        true
      end
    end

    def clear_policy_taint_after_recovery(policy_root_removed:)
      sync do
        return false unless policy_root_removed

        changed = clear_policy_taint_without_runtime_locked(
          'explicit recovery removed and verified the stable cgroup hierarchy'
        )
        commit if changed
        changed
      end
    end

    # Persist a marker before the start effect or CtPreStart callback changes
    # the shared stable hierarchy. A dead launch worker is then recoverable as
    # a policy taint instead of leaving undetected partial kernel writes.
    def begin_launch_policy(run_id, kind:)
      worker = ProcessIdentity.capture_thread
      return unless worker

      sync do
        return if live_policy_update_locked
        return if effective_policy_tainted_locked?

        run = find_run_locked(run_id)
        return unless launch_policy_current_locked?(run)

        lease_id = SecureRandom.uuid
        record['policy_update'] = {
          'id' => lease_id,
          'kind' => kind.to_s,
          'scope' => 'launch',
          'run_id' => load_run_id(run).dump,
          'worker' => worker.dump,
          'started_at' => Time.now.to_f,
          'record_revision' => revision + 1,
          'started_tainted' => policy_tainted_locked?
        }
        commit

        PolicyLease.new(id: lease_id, revision:)
      end
    end

    # The start/execute effect owns topology creation, so it cannot acquire a
    # stable-runtime policy lease. Record both the pre-LXC parent transaction
    # and the post-LXC child reconciliation against the exact launching run.
    def record_launch_policy(
      run_id,
      lease_id:,
      target:,
      run_masks: {},
      error: nil,
      rollback_error: nil
    )
      sync do
        update = record['policy_update']
        return false unless update&.fetch('id') == lease_id
        return false unless update['scope'] == 'launch'

        run = find_run_locked(run_id)
        return false unless run
        return false unless active_run_locked.equal?(run)
        return false if run['recovery']
        return false unless Container::RunId.load(update.fetch('run_id')) == load_run_id(run)

        policy_revision = complete_policy_update_locked(
          update,
          target:,
          error:,
          rollback_error:
        )

        if !error && update.fetch('kind') == 'cpuset_cpus'
          run_masks.each do |run_key, mask|
            policy_run = find_run_locked(run_key)
            next unless policy_run

            policy_run['policy'] = {
              'cpuset_cpus' => mask,
              'record_revision' => policy_revision
            }
          end
        end

        commit
        true
      end
    end

    def finish_policy_update(
      lease_id,
      target: nil,
      run_masks: {},
      error: nil,
      rollback_error: nil
    )
      sync do
        return unless record.dig('policy_update', 'id') == lease_id

        update = record['policy_update']
        policy_revision = complete_policy_update_locked(
          update,
          target:,
          error:,
          rollback_error:
        )

        unless error
          run_masks.each do |run_key, mask|
            run = find_run_locked(run_key)
            next unless run

            run['policy'] = {
              'cpuset_cpus' => mask,
              'record_revision' => policy_revision
            }
          end
        end

        commit
        active = active_run_locked
        effect_id = (active && claim_finalize_locked(active)) || nil
        PolicyCompletion.new(
          run_id: active && load_run_id(active),
          effect_id:
        )
      end
    end

    def finish_parent_policy_update(
      lease_id,
      error: nil
    )
      sync do
        update = record['policy_update']
        return unless update&.fetch('id') == lease_id
        return unless update['scope'] == 'parent'

        record['policy_update'] = nil
        pending_hazards = update.fetch('pending_hazards', [])
        install_pending_policy_hazards_locked(
          pending_hazards,
          reconciliation: {
            'at' => Time.now.to_f,
            'target' => nil,
            'error' => error,
            'rollback_error' => nil
          }
        )
        commit
        active = active_run_locked
        effect_id = (active && claim_finalize_locked(active)) || nil
        PolicyCompletion.new(
          run_id: active && load_run_id(active),
          effect_id:
        )
      end
    end

    def manipulation_blocker(allow_policy_taint: false)
      sync do
        policy_update = live_policy_update_locked
        if policy_update
          next {
            phase: 'policy_update',
            effect: policy_update['kind'],
            recovery: false,
            observer: false,
            reconciliation: false,
            callbacks: 0,
            processes: 0
          }
        end

        if effective_policy_tainted_locked? && !allow_policy_taint
          next {
            phase: 'policy_tainted',
            effect: record.dig('policy', 'kind'),
            recovery: false,
            observer: false,
            reconciliation: false,
            callbacks: 0,
            processes: 0,
            hazard: policy_taint_warning_locked
          }
        end

        active = active_run_locked
        next unless active
        next if stable_runtime_locked?(active)

        {
          phase: active.fetch('phase'),
          effect: active.dig('effect', 'type'),
          recovery: !active['recovery'].nil?,
          observer: !active['observer'].nil?,
          reconciliation: !active['reconciliation'].nil?,
          callbacks: active.fetch('callbacks', {}).length,
          processes: active.fetch('processes', {}).length
        }
      end
    end

    def snapshot
      sync do
        live_policy_update_locked
        deep_copy(record)
      end
    end

    def revision
      record.fetch('revision')
    end

    def adopt_legacy(run_conf, state, managers: [])
      sync do
        return if active_run_locked

        run_id = run_conf.run_id
        hazards = ['adopted legacy runtime']
        if state.to_sym != :stopped && managers.empty?
          hazards << 'legacy manager identity unavailable'
        end
        record.fetch('runs')[run_id.to_s] = {
          'id' => run_id.dump,
          'role' => 'active',
          'kind' => 'container',
          'phase' => state.to_s,
          'created_at' => run_id.timestamp,
          'launch_intent_id' => current_intent_id_locked,
          'observations' => {
            'adoption' => {
              'state' => state.to_s,
              'at' => Time.now.to_f,
              'record_revision' => revision + 1
            }
          },
          'resources' => generation_resources(run_id, legacy: true),
          'hazards' => hazards,
          'post_stop' => state.to_sym == :stopped,
          'reported_state' => state.to_s,
          'running_effects_started' => state.to_sym == :running,
          'running_effects_done' => state.to_sym == :running,
          'on_stop_hook_started' => false,
          'on_stop_hook_done' => false,
          'post_stop_hook_started' => false,
          'post_stop_hook_done' => false,
          'wrapper_gone' => state.to_sym == :stopped,
          'reboot' => run_conf.reboot?,
          'pre_start_consumed' => true,
          'pre_start_completed' => true,
          'pre_start_callback_id' => nil,
          'lxc_start_authorized' => true,
          'legacy_callbacks' => true,
          'legacy_managers' => deep_copy(managers),
          'observer' => nil,
          'reconciliation' => nil,
          'callbacks' => {},
          'processes' => {},
          'recovery' => nil,
          'effect' => nil
        }
        record['active_run_id'] = run_id.to_s
        record['desired_state'] = state.to_sym == :running ? 'running' : 'stopped'
        commit
      end
    end

    def log_type
      "lifecycle=#{ct.pool.name}:#{ct.id}"
    end

    protected

    attr_reader :ct, :record

    # Process exit does not itself change the reducer revision. Keep a durable
    # watcher for every registered identity so a dead owner is removed and
    # post-stop finalization can be claimed without waiting for an unrelated
    # command to touch the lifecycle record.
    def watch_process(run_id, process_id)
      thread = Thread.new do
        loop do
          expected_identity = sync do
            run = find_run_locked(run_id)
            process = run&.dig('processes', process_id)
            process && deep_copy(process.fetch('identity'))
          end
          break unless expected_identity

          if ProcessIdentity.load(expected_identity).alive?
            sleep(PROCESS_WORKER_RECHECK_INTERVAL)
            next
          end

          removed, effect_id, exact_run_id =
            finish_dead_process(
              run_id,
              process_id,
              expected_identity
            )
          unless removed
            sleep(PROCESS_WORKER_RECHECK_INTERVAL)
            next
          end

          spawn_process_finalizer(exact_run_id, effect_id) if effect_id
          break
        end
      rescue StandardError => e
        log(
          :warn,
          "Unable to watch lifecycle process #{process_id}: " \
          "#{e.message} (#{e.class})"
        )
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def finish_dead_process(run_id, process_id, expected_identity)
      sync do
        run = find_run_locked(run_id)
        return [false, nil, nil] unless run

        process = run.fetch('processes', {})[process_id]
        return [false, nil, nil] unless process
        return [false, nil, nil] \
          unless process.fetch('identity') == expected_identity
        return [false, nil, nil] if process_alive_locked?(process)

        run.fetch('processes').delete(process_id)
        commit
        [true, claim_finalize_locked(run), load_run_id(run)]
      end
    end

    def spawn_process_finalizer(run_id, effect_id)
      run_conf = []
      run_conf << ct.run_conf if ct.respond_to?(:run_conf)
      run_conf << ct.get_past_run_conf \
        if ct.respond_to?(:get_past_run_conf)
      exact = run_conf.compact.detect do |conf|
        conf.run_id.to_s == run_id.to_s
      end

      if exact
        require 'osctld/container/lifecycle_finalizer'
        Container::LifecycleFinalizer.spawn(ct, exact, effect_id)
      else
        fail_cleanup(
          run_id,
          effect_id,
          'exact run configuration is missing'
        )
      end
    end

    def process_alive_locked?(process)
      return true if ProcessIdentity.load(
        process.fetch('identity')
      ).alive?

      supervisor = process['supervisor']
      supervisor && ProcessIdentity.load(supervisor).alive?
    end

    def sync(&)
      @mutex.synchronize(&)
    end

    def default_record
      {
        'schema' => SCHEMA,
        'incarnation_id' => ct.incarnation_id,
        'revision' => 0,
        'desired_state' => 'stopped',
        'intent' => nil,
        'active_run_id' => nil,
        'runs' => {}
      }
    end

    def validate_record!
      raise ConfigError, "unsupported lifecycle schema #{record['schema']}" \
        unless record['schema'] == SCHEMA

      return if record['incarnation_id'] == ct.incarnation_id

      unless discardable_incarnation_record?
        raise ConfigError,
              "container #{ct.pool.name}:#{ct.id}: lifecycle incarnation " \
              "#{record['incarnation_id']} has runtime or quarantined policy " \
              'evidence; refusing configuration incarnation ' \
              "#{ct.incarnation_id}"
      end

      stale = "#{file_path}.incarnation-#{record['incarnation_id']}"
      stale = "#{stale}-#{SecureRandom.hex(4)}" if File.exist?(stale)
      File.rename(file_path, stale)
      @record = default_record
    end

    def discardable_incarnation_record?
      return false unless record['active_run_id'].nil?
      return false unless record['desired_state'] == 'stopped'
      return false if record['policy_update']
      return false if record.dig('policy', 'tainted')

      record.fetch('runs').values.all? do |run|
        run['role'] == 'history' \
          && run['effect'].nil? \
          && run['observer'].nil? \
          && run['reconciliation'].nil? \
          && run['recovery'].nil? \
          && run.fetch('callbacks', {}).empty? \
          && run.fetch('processes', {}).empty?
      end
    end

    def load_record
      OsCtl::Lib::ConfigFile.load_yaml_file(file_path)
    rescue Errno::ENOENT
      nil
    end

    def update_intent(desired_state, kind, source)
      record['desired_state'] = desired_state
      record['intent'] = {
        'id' => SecureRandom.uuid,
        'kind' => kind,
        'source' => source,
        'at' => Time.now.to_f
      }
    end

    def commit
      record['revision'] = revision + 1
      save_record
      @cv.broadcast
    end

    def save_record
      dir = File.dirname(file_path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      replacement = "#{file_path}.new-#{SecureRandom.hex(4)}"

      File.open(replacement, File::WRONLY | File::CREAT | File::EXCL, 0o400) do |f|
        f.write(OsCtl::Lib::ConfigFile.dump_yaml(record))
        f.flush
        f.fsync
      end

      File.rename(replacement, file_path)

      File.open(dir, File::RDONLY, &:fsync)
    ensure
      File.unlink(replacement) if replacement && File.exist?(replacement)
    end

    def file_path
      File.join(ct.pool.ct_dir, ct.id, 'lifecycle.yml')
    end

    def run_key(run_id)
      run_id.respond_to?(:to_s) ? run_id.to_s : run_id
    end

    def find_run_locked(run_id)
      record.fetch('runs')[run_key(run_id)]
    end

    def require_run_locked(run_id)
      find_run_locked(run_id) || raise("lifecycle run #{run_key(run_id)} not found")
    end

    def active_run_locked
      key = record['active_run_id']
      key && record.fetch('runs')[key]
    end

    def load_run_id(run)
      Container::RunId.load(run.fetch('id'))
    end

    def require_effect_locked(run_id, effect_id)
      run = require_run_locked(run_id)
      return if run['recovery']

      effect = run['effect']
      effect if effect && effect['id'] == effect_id
    end

    def claim_state_effects_locked(run, state)
      state_s = state.to_s
      return false if run['reported_state'] == state_s

      if state.to_sym == :running
        return false if run.fetch('running_effects_started', false)

        run['running_effects_started'] = true
      end

      run['reported_state'] = state_s
      commit
      true
    end

    def clear_stale_reconciliation_locked(run)
      reconciliation = run['reconciliation']
      return false unless reconciliation

      worker = reconciliation['worker']
      if worker && ProcessIdentity.load(worker).alive?
        return false
      end

      run['hazards'] << \
        "superseded stale reconciliation #{reconciliation['id']}"
      run['reconciliation'] = nil
      true
    end

    def claim_finalize_locked(run)
      return false unless active_run_locked.equal?(run)
      return false unless run['post_stop'] && run['wrapper_gone']
      return false if run['effect'] || run['observer'] || run['reconciliation']
      return false if record['policy_update']
      return false if run['recovery'] || live_workers_locked(run).any?

      effect_id = SecureRandom.uuid
      run['phase'] = 'cleaning'
      run['effect'] = {
        'id' => effect_id,
        'type' => 'cleanup',
        'record_revision' => revision + 1,
        'worker' => nil,
        'status' => 'claimed'
      }
      commit
      effect_id
    end

    def stable_runtime_locked?(active)
      active['phase'] == 'running' \
        && !active['observer'] \
        && !active['reconciliation'] \
        && !active['recovery'] \
        && live_workers_locked(active).empty? \
        && active['effect'].nil? \
        && record['desired_state'] == 'running' \
        && current_intent_id_locked == active['launch_intent_id']
    end

    def launch_policy_current_locked?(run)
      return false unless run
      return false unless active_run_locked.equal?(run)
      return false if run['recovery']
      return false unless %w[preparing launching starting].include?(run['phase'])

      %w[start execute].include?(run.dig('effect', 'type')) \
        || run['lxc_start_authorized']
    end

    def policy_tainted_locked?
      record.dig('policy', 'tainted') == true
    end

    def effective_policy_tainted_locked?
      policy_tainted_locked? || !inherited_group_policy_state_locked.nil?
    end

    def policy_taint_warning_locked
      inherited = inherited_group_policy_state_locked
      if inherited
        group, state = inherited
        detail = state['rollback_error'] || state['error'] || state['status']
        return [
          "ancestor group #{group.pool.name}:#{group.name} cgroup policy is quarantined",
          detail,
          "run 'osctl group cgparams apply " \
          "#{group.pool.name}:#{group.name}' before starting containers"
        ].compact.join(': ')
      end

      policy = record.fetch('policy')
      detail = policy['rollback_error'] || policy['error']

      [
        'container cgroup policy is tainted',
        detail,
        'remove the affected cgroups with explicit recovery'
      ].compact.join(': ')
    end

    def inherited_group_policy_state_locked
      return unless ct.respond_to?(:group)

      group = ct.group
      return unless group.respond_to?(:inherited_cgroup_policy_state)

      group.inherited_cgroup_policy_state
    end

    def policy_taint_blocks_callback_locked?(name)
      effective_policy_tainted_locked? \
        && !TAINT_SAFE_CALLBACKS.include?(name.to_s)
    end

    def clear_policy_taint_without_runtime_locked(reason)
      return false unless policy_tainted_locked?
      return false if record.fetch('runs').values.any? do |run|
        %w[active residual].include?(run['role'])
      end

      record['policy']['tainted'] = false
      record['policy']['recovered_at'] = Time.now.to_f
      record['policy']['recovery'] = reason
      true
    end

    def live_policy_update_locked
      update = record['policy_update']
      return unless update

      worker = update['worker'] && ProcessIdentity.load(update['worker'])
      return update if worker&.alive?

      if update['scope'] == 'parent'
        record['policy_update'] = nil
        pending_hazards = update.fetch('pending_hazards', [])
        install_pending_policy_hazards_locked(
          pending_hazards,
          reconciliation: {
            'at' => Time.now.to_f,
            'target' => nil,
            'error' =>
              'parent policy worker disappeared before completing the ' \
              'transaction',
            'rollback_error' => nil
          }
        )
        commit
        return
      end

      complete_policy_update_locked(
        update,
        target: nil,
        error: 'policy worker disappeared before completing the transaction',
        rollback_error: 'runtime cgroup policy may be partially applied'
      )
      commit
      nil
    end

    def complete_policy_update_locked(
      update,
      target:,
      error:,
      rollback_error:
    )
      previous_policy = record['policy']
      record['policy_update'] = nil
      policy_revision = revision + 1
      started_tainted = update.fetch('started_tainted', false)
      pending_hazards = update.fetch('pending_hazards', [])
      worker_tainted = !rollback_error.nil?
      pending_hazard = pending_hazards.last
      tainted = worker_tainted || started_tainted || !pending_hazards.empty?
      promoted_hazard =
        if started_tainted || worker_tainted
          nil
        else
          pending_hazard
        end
      record['policy'] = {
        'kind' => promoted_hazard&.fetch('kind') || update.fetch('kind'),
        'target' => promoted_hazard&.fetch('target') || target,
        'applied_at' => promoted_hazard&.fetch('at') || Time.now.to_f,
        'record_revision' => policy_revision,
        'error' =>
          if started_tainted
            previous_policy&.fetch('error', nil)
          else
            promoted_hazard&.fetch('error') || error
          end,
        'rollback_error' =>
          if started_tainted
            previous_policy&.fetch('rollback_error', nil)
          else
            promoted_hazard&.fetch('rollback_error') || rollback_error
          end,
        'tainted' => tainted
      }
      retained_hazards = []
      if started_tainted && previous_policy
        retained_hazards.concat(previous_policy.fetch('pending_hazards', []))
      end
      retained_hazards.concat(pending_hazards)
      unless retained_hazards.empty?
        record['policy']['pending_hazards'] = retained_hazards
      end
      if started_tainted || pending_hazard
        record['policy']['last_reconciliation'] = {
          'at' => Time.now.to_f,
          'target' => target,
          'error' => error,
          'rollback_error' => rollback_error
        }
      end

      policy_revision
    end

    def install_pending_policy_hazards_locked(hazards, reconciliation:)
      return if hazards.empty?

      hazard = hazards.last
      record['policy'] = {
        'kind' => hazard.fetch('kind'),
        'target' => hazard.fetch('target'),
        'applied_at' => hazard.fetch('at'),
        'record_revision' => revision + 1,
        'error' => hazard.fetch('error'),
        'rollback_error' => hazard.fetch('rollback_error'),
        'tainted' => true,
        'pending_hazards' => hazards,
        'last_reconciliation' => reconciliation
      }
    end

    def live_workers_locked(run)
      workers = []

      run.fetch('callbacks', {}).delete_if do |_id, callback|
        identity = ProcessIdentity.load(callback.fetch('worker'))
        alive = identity.alive?
        workers << callback.merge('kind' => 'callback') if alive
        !alive
      end

      run.fetch('processes', {}).delete_if do |_id, process|
        alive = process_alive_locked?(process)
        if alive
          workers << process.merge(
            'kind' => 'process',
            'worker' => process.fetch('identity')
          )
        end
        !alive
      end

      workers
    end

    def generation_resources(run_id, legacy: false, kind: 'container')
      root =
        if legacy
          ct.base_cgroup_path
        else
          File.join(ct.base_cgroup_path, 'runs', run_id.key)
        end
      user_cgroup =
        legacy ? ct.legacy_cgroup_path : File.join(root, 'user-owned')
      wrapper_cgroup =
        if legacy
          ct.legacy_wrapper_cgroup_path
        elsif kind == 'execution'
          File.join(user_cgroup, 'wrapper')
        else
          File.join(root, 'wrapper')
        end

      {
        'cgroup_root' => root,
        'user_cgroup' => user_cgroup,
        'wrapper_cgroup' => wrapper_cgroup,
        'host_effects' => File.join(root, 'host-effects'),
        'lxc_payload' => File.join(
          user_cgroup,
          legacy ? "lxc.payload.#{ct.id}" : 'payload'
        ),
        'lxc_monitor' => File.join(
          user_cgroup,
          legacy ? "lxc.monitor.#{ct.id}" : 'monitor'
        ),
        'lxc_pivot' => File.join(
          user_cgroup,
          legacy ? "lxc.pivot.#{ct.id}" : 'monitor-pivot'
        ),
        'lxc_inner' => File.join(
          user_cgroup,
          legacy ? "lxc.payload.#{ct.id}/inner" : 'payload/inner'
        ),
        'run_config' => File.join(ct.pool.ct_dir, ct.id, "config.#{run_id.key}.yml"),
        'lxc_config' => File.join(ct.lxc_dir, "config.#{run_id.key}"),
        'apparmor_profile' => "ct-#{ct.pool.name}-#{ct.id}-#{run_id.key}",
        'apparmor_namespace' => "lxc-ct-#{ct.pool.name}-#{ct.id}-#{run_id.key}"
      }
    end

    def current_intent_id_locked
      record.dig('intent', 'id')
    end

    def pending_running_intent?(run)
      record['desired_state'] == 'running' \
        && current_intent_id_locked \
        && current_intent_id_locked != run['launch_intent_id']
    end

    def container_run_locked?(run)
      run.fetch('kind', 'container') == 'container'
    end

    def execution_run_locked?(run)
      run.fetch('kind', 'container') == 'execution'
    end

    def restart_intent_id_locked(run)
      current_intent_id_locked if pending_running_intent?(run)
    end

    def run_ending?(run)
      %w[stopping post_stop cleaning].include?(run['phase'])
    end

    def apply_state_observation_locked(run, state, init_pid:)
      case state.to_sym
      when :starting
        run['phase'] = 'starting'
      when :running
        run['phase'] = 'running'
        run['init'] = ProcessIdentity.capture(init_pid)&.dump if init_pid
      when :stopping, :aborting
        run['phase'] = 'stopping'
        run['aborted'] = true if state.to_sym == :aborting
      when :stopped, :aborted
        run['aborted'] = true if state.to_sym == :aborted
        run['phase'] = 'post_stop' if run['post_stop']
      end
    end

    def superseded_request
      Request.new(
        action: :superseded,
        revision:,
        intent_id: current_intent_id_locked,
        warning: 'lifecycle intent was superseded by a newer request'
      )
    end

    def residual_warning_locked
      count = record.fetch('runs').values.count { |run| run['role'] == 'residual' }
      return if count == 0

      "#{count} residual container generation#{count == 1 ? '' : 's'} remain; " \
        'already-entered kernel I/O may still complete'
    end

    def prune_clean_runs
      record.fetch('runs').delete_if do |_key, run|
        run['role'] == 'history' && run['phase'] == 'clean'
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def daemon_stopping?
      OsCtld.const_defined?(:Daemon) && Daemon.get&.stopping?
    end
  end
end
