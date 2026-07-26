require 'osctld/cgroup/params'
require 'osctld/cgroup/cpuset_policy'
require 'osctld/cgroup/cpu_bandwidth_policy'
require 'osctld/cpu_scheduler'

module OsCtld
  class CGroup::ContainerParams < CGroup::Params
    CPUSET_PARAMETER = 'cpuset.cpus'.freeze

    def set(*args, configure: true, **kwargs)
      owner.exclusively do
        super(*args, **kwargs)
        owner.lxc_config.configure_cgparams if configure
      end
    end

    # Stage a cpuset-bearing update, apply it to the complete live hierarchy,
    # and only then persist the container and LXC configurations.
    def transactional_set(new_params, append: false, apply: true, &path)
      before = snapshot_params
      set(new_params, append:, save: false, configure: false)
      staged = snapshot_params
      target =
        if cpuset_mutation?(new_params) && cpuset_runtime_active?
          cpuset_target(staged)
        end

      parameter_transaction(
        before,
        staged,
        target:,
        policy_kind: runtime_policy_kind(new_params, target:),
        rollback_non_cpuset: apply,
        path:
      ) do
        if apply
          apply_non_cpuset_strict(
            keep_going: false,
            policy_lease: false,
            &path
          )
        end
      end
    end

    def transactional_unset(
      del_params,
      reset: true,
      keep_going: false,
      &path
    )
      before = snapshot_params
      deleted = find_params(before, del_params)
      if reset
        validate_strict_resets!(
          deleted.reject { |param| cpuset_param?(param) },
          &path
        )
      end
      unset(del_params, save: false, reset: false)
      staged = snapshot_params
      cpuset_deleted = deleted.any? { |param| cpuset_param?(param) }
      target =
        if cpuset_deleted && cpuset_runtime_active?
          cpuset_target(staged) || default_cpuset_target
        end

      parameter_transaction(
        before,
        staged,
        target:,
        policy_kind: runtime_policy_kind(deleted, target:),
        rollback_non_cpuset: reset,
        path:
      ) do
        next unless reset

        reset_non_cpuset_params_strict(
          deleted.reject { |param| cpuset_param?(param) },
          keep_going,
          &path
        )
      end
    end

    def transactional_replace(new_params, &path)
      before = snapshot_params
      removed = before.reject do |param|
        new_params.any? { |new_param| same_param?(param, new_param) }
      end
      validate_strict_resets!(
        removed.reject { |param| cpuset_param?(param) },
        &path
      )
      replace_params(new_params)
      staged = snapshot_params
      target =
        if cpuset_runtime_active?
          cpuset_target(staged) || default_cpuset_target
        end

      parameter_transaction(
        before,
        staged,
        target:,
        policy_kind:
          runtime_policy_kind(before + staged, target:),
        rollback_non_cpuset: true,
        path:
      ) do
        reset_non_cpuset_params_strict(
          removed.reject { |param| cpuset_param?(param) },
          true,
          &path
        )
        apply_non_cpuset_strict(
          keep_going: true,
          policy_lease: false,
          &path
        )
      end
    end

    def apply(keep_going: false, cpuset: true, &path)
      apply_non_cpuset_strict(keep_going:, &path)

      target = cpuset_target
      return unless cpuset && target

      unless cpuset_runtime_active?
        if owner.lifecycle.policy_tainted?
          raise CGroup::CpusetPolicy::Error,
                'tainted cgroup policy has no runtime hierarchy; ' \
                'remove the affected cgroups with explicit recovery'
        end
        return
      end

      apply_cpuset_with_lease(target)
    end

    # Reapply persisted parameters from an exact managed launch callback. The
    # callback already owns the generation, but CPU hierarchy writes need a
    # durable launch-policy marker so an interrupted rollback is quarantined.
    def apply_for_start(run_id:, keep_going: false, &path)
      apply_non_cpuset_strict(
        keep_going:,
        policy_lease: false,
        launch_run_id: run_id,
        &path
      )
    end

    def reset(param, keep_going, &)
      if cpuset_param?(param)
        return unless cpuset_runtime_active?

        apply_cpuset_with_lease(default_cpuset_target)
        return
      end

      super
      return unless runtime_active?

      reset_container_param(param, keep_going)
    end

    # Called by the exact start effect after CPU scheduling has selected and
    # staged its non-persistent cpuset parameter. The start effect itself owns
    # the generation topology, so a second lifecycle lease is neither needed
    # nor admissible while the run is preparing.
    def apply_cpuset_for_start(run_id:)
      target = cpuset_target
      return unless target

      prepare_launch_cpuset_root(run_id)
      apply_launch_policy(
        run_id,
        kind: :cpuset_cpus,
        target:
      ) do
        CGroup::CpusetPolicy.new(owner, target).apply
      end
    end

    # Temporarily expand container memory by given percentage
    def temporarily_expand_memory(percent: 50)
      return unless owner.running?

      if CGroup.v1?
        temporarily_expand_memory_v1(percent:)
      else
        temporarily_expand_memory_v2(percent:)
      end
    end

    protected

    def runtime_active?
      return true if owner.running?

      run_conf = owner.run_conf
      run_conf && owner.lifecycle.active_run_id == run_conf.run_id
    end

    def cpuset_runtime_active?
      return true if runtime_active?
      return true if owner.lifecycle.residuals.any?

      File.exist?(
        File.join(
          CGroup.abs_cgroup_path('cpuset', owner.base_cgroup_path),
          CPUSET_PARAMETER
        )
      )
    end

    def apply_non_cpuset(keep_going:, &path)
      selected = usable_params.reject { |param| cpuset_param?(param) }
      apply_params_and_retry(selected, keep_going:, &path)
      return unless runtime_active?

      apply_container_params_and_retry(selected, keep_going:)
    end

    def apply_non_cpuset_strict(
      keep_going:,
      policy_lease: true,
      launch_run_id: nil,
      &path
    )
      selected = usable_params.reject { |param| cpuset_param?(param) }
      cpu_bandwidth, ordinary = selected.partition do |param|
        cpu_bandwidth_param?(param)
      end

      apply_params_strict(ordinary, keep_going:, &path)

      if cpu_bandwidth.any?
        if cpu_bandwidth_runtime_active?
          if launch_run_id
            apply_cpu_bandwidth_for_start(
              cpu_bandwidth,
              root: path.call('cpu'),
              run_id: launch_run_id
            )
          elsif policy_lease
            apply_cpu_bandwidth_with_lease(
              cpu_bandwidth,
              root: path.call('cpu')
            )
          else
            CGroup::CpuBandwidthPolicy.new(
              owner,
              cpu_bandwidth,
              root: path.call('cpu')
            ).apply
          end
        else
          apply_params_strict(cpu_bandwidth, keep_going:, &path)
        end
      end

      return unless runtime_active?

      apply_container_params_strict(ordinary, keep_going:)
    end

    def temporarily_expand_memory_v1(percent:)
      # Determine new memory limits
      mem_limit = each_usable.detect { |p| p.name == 'memory.limit_in_bytes' }
      memsw_limit = each_usable.detect { |p| p.name == 'memory.memsw.limit_in_bytes' }

      tmp_params = [mem_limit, memsw_limit].map do |p|
        next if p.nil?

        cur_limit = p.value.last.to_i
        new_limit = (cur_limit + (cur_limit / 100.0 * percent)).round

        CGroup::Param.new(1, 'memory', p.name, [new_limit], false)
      end

      tmp_params.compact!

      return if tmp_params.empty?

      # Apply new memory limits
      return unless owner.running?

      # First apply them on ct.<id>
      apply_params_and_retry(tmp_params, keep_going: true) do |subsystem|
        owner.abs_apply_cgroup_path(subsystem)
      end

      # Then apply them on lxc.payload
      apply_container_params_and_retry(tmp_params, keep_going: true)

      nil
    end

    def temporarily_expand_memory_v2(percent:)
      # Determine new memory limit
      memory_max = each_usable.detect { |p| p.name == 'memory.max' }
      return if memory_max.nil?

      cur_limit = memory_max.value.last.to_i
      new_limit = (cur_limit + (cur_limit / 100.0 * percent)).round

      new_param = CGroup::Param.new(2, 'memory', 'memory.max', [new_limit], false)

      # Apply new memory limits
      return unless owner.running?

      # First apply them on ct.<id>
      apply_params_and_retry([new_param], keep_going: true) do |subsystem|
        owner.abs_apply_cgroup_path(subsystem)
      end

      # Then apply them on lxc.payload
      apply_container_params_and_retry([new_param], keep_going: true)

      nil
    end

    def apply_container_params(param_list, keep_going: false)
      failed = []

      param_list.each do |param|
        path = File.join(
          CGroup.abs_cgroup_path(
            param.subsystem,
            owner.lxc_payload_cgroup_path
          ),
          param.name
        )

        begin
          failed << param unless CGroup.set_param(path, param.value)
        rescue CGroupFileNotFound
          raise unless keep_going

          next
        end
      end

      failed
    end

    def apply_container_params_and_retry(param_list, keep_going: false)
      failed = apply_container_params(
        param_list,
        keep_going:
      ).select { |param| param.name.start_with?('memory.') }

      return unless failed.any?

      apply_container_params(failed, keep_going:)
    end

    def apply_params_strict(param_list, keep_going:, &path)
      failed = apply_params(param_list, keep_going:, &path)
      memory, final = failed.partition do |param|
        param.name.start_with?('memory.')
      end
      final.concat(apply_params(memory, keep_going:, &path)) if memory.any?
      raise_failed_writes(final, 'stable container cgroup')
    end

    def apply_container_params_strict(param_list, keep_going:)
      failed = apply_container_params(param_list, keep_going:)
      memory, final = failed.partition do |param|
        param.name.start_with?('memory.')
      end
      if memory.any?
        final.concat(apply_container_params(memory, keep_going:))
      end
      raise_failed_writes(final, 'LXC payload cgroup')
    end

    def raise_failed_writes(params, location)
      return if params.empty?

      names = params.map(&:name).uniq.join(', ')
      raise CGroup::CpusetPolicy::Error,
            "kernel rejected #{location} parameters: #{names}"
    end

    def reset_non_cpuset_strict(param, keep_going, &path)
      return unless param.version == CGroup.version

      value = reset_value(param)
      return unless value

      set_param_strict(
        File.join(path.call(param.subsystem), param.name),
        value,
        keep_going:
      )
      return unless runtime_active?

      set_param_strict(
        File.join(
          CGroup.abs_cgroup_path(
            param.subsystem,
            owner.lxc_payload_cgroup_path
          ),
          param.name
        ),
        value,
        keep_going:
      )
    end

    def reset_non_cpuset_params_strict(param_list, keep_going, &path)
      cpu_bandwidth, ordinary = param_list.partition do |param|
        cpu_bandwidth_param?(param)
      end
      ordinary.each do |param|
        reset_non_cpuset_strict(param, keep_going, &path)
      end
      return if cpu_bandwidth.empty?

      resets = cpu_bandwidth.filter_map do |param|
        value = reset_value(param)
        next unless value

        CGroup::Param.new(
          param.version,
          param.subsystem,
          param.name,
          value,
          false
        )
      end
      return if resets.empty?

      if cpu_bandwidth_runtime_active?
        CGroup::CpuBandwidthPolicy.new(
          owner,
          resets,
          root: path.call('cpu')
        ).apply
      else
        apply_params_strict(resets, keep_going:, &path)
      end
    end

    def validate_strict_resets!(param_list, &path)
      participates =
        runtime_active? \
        || cpuset_runtime_active? \
        || (
          path \
          && param_list.any? do |param|
            File.exist?(File.join(path.call(param.subsystem), param.name))
          end
        )
      return unless participates

      unsupported = param_list.select do |param|
        param.version == CGroup.version && reset_value(param).nil?
      end
      return if unsupported.empty?

      names = unsupported.map(&:name).uniq.join(', ')
      raise CGroup::CpusetPolicy::Error,
            "no runtime reset value is known for #{names}"
    end

    def set_param_strict(path, value, keep_going:)
      return if CGroup.set_param(path, value)

      raise CGroup::CpusetPolicy::Error,
            "kernel rejected cgroup parameter #{path}"
    rescue CGroupFileNotFound
      raise unless keep_going

      log(
        :info,
        :cgroup,
        "Skip #{path}, group or parameter does not exist"
      )
    end

    def reset_container_param(param, keep_going)
      value = reset_value(param)
      return unless value

      path = File.join(
        CGroup.abs_cgroup_path(
          param.subsystem,
          owner.lxc_payload_cgroup_path
        ),
        param.name
      )
      CGroup.set_param(path, value)
    rescue CGroupFileNotFound
      raise unless keep_going

      log(
        :info,
        :cgroup,
        "Skip #{path}, group or parameter does not exist"
      )
    end

    def parameter_transaction(
      before,
      staged,
      target:,
      policy_kind:,
      rollback_non_cpuset:,
      path:
    )
      if target.nil? \
          && policy_kind.nil? \
          && owner.lifecycle.policy_tainted?
        raise CGroup::CpusetPolicy::Error,
              'tainted cgroup policy has no runtime hierarchy; ' \
              'remove the affected cgroups with explicit recovery'
      end

      lease_target =
        target \
        || staged.select do |param|
          param.version == CGroup.version && cpu_limit_param?(param)
        end.map(&:dump)
      lease = policy_kind && begin_policy_lease(policy_kind)
      policy_result = target && CGroup::CpusetPolicy.new(owner, target).apply

      yield
      persist_params
    rescue StandardError => e
      rollback_errors = []
      restore_params(before)

      if policy_result
        begin
          old_target = cpuset_target(before) || default_cpuset_target
          CGroup::CpusetPolicy.new(owner, old_target).apply
        rescue StandardError => rollback_error
          rollback_errors << rollback_error.message
        end
      elsif e.is_a?(CGroup::CpusetPolicy::Error) && e.rollback_error
        rollback_errors << e.rollback_error.message
      end

      if rollback_non_cpuset
        begin
          rollback_non_cpuset_params(before, staged, &path)
        rescue StandardError => rollback_error
          rollback_errors << rollback_error.message
        end
      end

      begin
        persist_params
      rescue StandardError => rollback_error
        rollback_errors << rollback_error.message
      end

      finish_policy_lease(
        lease,
        target: lease_target,
        error: e.message,
        rollback_error: rollback_errors.empty? ? nil : rollback_errors.join('; ')
      )

      message = "unable to update container cgroup parameters: #{e.message}"
      unless rollback_errors.empty?
        message = "#{message}; rollback failed: #{rollback_errors.join('; ')}"
      end
      raise CGroup::CpusetPolicy::Error, message
    else
      finish_policy_lease(
        lease,
        result: policy_result,
        target: lease_target
      )
      nil
    end

    def apply_cpuset_with_lease(target)
      lease = begin_policy_lease(:cpuset_cpus)
      result = CGroup::CpusetPolicy.new(owner, target).apply
    rescue StandardError => e
      finish_policy_lease(
        lease,
        target:,
        error: e.message,
        rollback_error: e.respond_to?(:rollback_error) \
          && e.rollback_error&.message
      )
      raise
    else
      finish_policy_lease(lease, result:)
      result
    end

    def apply_cpu_bandwidth_for_start(params, root:, run_id:)
      apply_launch_policy(
        run_id,
        kind: :cpu_bandwidth,
        target: params.map(&:dump)
      ) do
        CGroup::CpuBandwidthPolicy.new(owner, params, root:).apply
      end
    end

    def apply_launch_policy(run_id, kind:, target:)
      lease = owner.lifecycle.begin_launch_policy(run_id, kind:)
      unless lease
        raise CGroup::CpusetPolicy::Error,
              'container lifecycle changed before launch policy could be fenced'
      end

      result = yield
      recorded = owner.lifecycle.record_launch_policy(
        run_id,
        lease_id: lease.id,
        target: result.target,
        run_masks: policy_run_masks(result)
      )
      unless recorded
        raise CGroup::CpusetPolicy::Error,
              'container lifecycle changed during launch policy application'
      end

      result
    rescue StandardError => e
      if lease
        owner.lifecycle.record_launch_policy(
          run_id,
          lease_id: lease.id,
          target:,
          error: e.message,
          rollback_error: e.respond_to?(:rollback_error) \
            && e.rollback_error&.message
        )
      end
      raise
    end

    def apply_cpu_bandwidth_with_lease(params, root:)
      lease = begin_policy_lease(:cpu_bandwidth)
      result = CGroup::CpuBandwidthPolicy.new(owner, params, root:).apply
    rescue StandardError => e
      finish_policy_lease(
        lease,
        target: params.map(&:dump),
        error: e.message,
        rollback_error: e.respond_to?(:rollback_error) \
          && e.rollback_error&.message
      )
      raise
    else
      finish_policy_lease(lease, result:)
      result
    end

    def begin_policy_lease(kind)
      lease = owner.lifecycle.begin_policy_update(kind:)
      return lease if lease

      raise CGroup::CpusetPolicy::Error,
            'container lifecycle changed before cgroup policy could be fenced'
    end

    def prepare_launch_cpuset_root(run_id)
      run = owner.lifecycle.run(run_id)
      unless run
        raise CGroup::CpusetPolicy::Error,
              'container lifecycle run disappeared during launch policy setup'
      end

      root = run.fetch('resources').fetch('cgroup_root')
      CGroup.mkpath('cpuset', root.split('/'), leaf: false)
    end

    def finish_policy_lease(
      lease,
      result: nil,
      target: result&.target,
      error: nil,
      rollback_error: nil
    )
      return unless lease

      completion = owner.lifecycle.finish_policy_update(
        lease.id,
        target:,
        run_masks: policy_run_masks(result),
        error:,
        rollback_error:
      )
      return unless completion&.effect_id

      run_conf = [owner.run_conf, owner.get_past_run_conf].compact.detect do |conf|
        conf.run_id == completion.run_id
      end

      if run_conf
        require 'osctld/container/lifecycle_finalizer'
        Container::LifecycleFinalizer.spawn(
          owner,
          run_conf,
          completion.effect_id
        )
      else
        owner.lifecycle.fail_cleanup(
          completion.run_id,
          completion.effect_id,
          'exact run configuration is missing'
        )
      end
    end

    def policy_run_masks(result)
      if result && result.respond_to?(:run_masks)
        result.run_masks
      else
        {}
      end
    end

    def rollback_non_cpuset_params(before, staged, &)
      added = staged.reject do |param|
        before.any? { |old_param| same_param?(param, old_param) }
      end
      reset_non_cpuset_params_strict(
        added.reject do |param|
          cpuset_param?(param) || param.version != CGroup.version
        end,
        true,
        &
      )

      apply_non_cpuset_strict(
        keep_going: true,
        policy_lease: false,
        &
      )
    end

    def persist_params
      owner.exclusively do
        owner.save_config
        configured = owner.lxc_config.configure_cgparams
        unless configured
          raise CGroup::CpusetPolicy::Error,
                'unable to render container LXC cgroup configuration'
        end
      end
    end

    def default_cpuset_target
      parent = CGroup::CpusetPolicy.parent_mask(owner)
      run_conf = owner.run_conf || owner.get_past_run_conf
      if run_conf&.cpu_package
        package = CpuScheduler.package_mask(run_conf.cpu_package)
        if package
          cpus =
            OsCtl::Lib::CpuMask.new(package).to_a \
            & OsCtl::Lib::CpuMask.new(parent).to_a
          if cpus.empty?
            raise CGroup::CpusetPolicy::Error,
                  "scheduler package #{package} is disjoint from parent #{parent}"
          end

          return OsCtl::Lib::CpuMask.format(cpus).to_s
        end
      end

      parent
    end

    def cpuset_target(list = params)
      param = list.reverse_each.detect { |item| cpuset_param?(item) }
      param && param.value.last.to_s
    end

    def cpuset_param?(param)
      param.version == CGroup.version && param.name == CPUSET_PARAMETER
    end

    def cpu_bandwidth_param?(param)
      return false unless param.version == CGroup.version
      return false unless param.subsystem == 'cpu'

      if CGroup.v1?
        CGroup::CpuBandwidthPolicy::V1_PARAMETERS.include?(param.name)
      else
        param.name == CGroup::CpuBandwidthPolicy::V2_PARAMETER
      end
    end

    def cpu_limit_param?(param)
      return false unless param.version == CGroup.version

      if CGroup.v1?
        cpu_bandwidth_param?(param)
      else
        param.subsystem == 'cpu' && param.name == 'cpu.max'
      end
    end

    def runtime_policy_kind(params, target:)
      return :cpuset_cpus if target
      return unless cpu_bandwidth_runtime_active?
      return unless params.any? { |param| cpu_limit_param?(param) }

      :cpu_bandwidth
    end

    def cpu_bandwidth_runtime_active?
      runtime_active? || owner.lifecycle.residuals.any?
    end

    def cpuset_mutation?(new_params)
      new_params.any? { |param| cpuset_param?(param) }
    end

    def find_params(list, specs)
      imported = specs.map { |spec| CGroup::Param.import(spec) }
      list.select do |param|
        imported.any? { |candidate| same_param?(param, candidate) }
      end
    end

    def same_param?(left, right)
      left.version == right.version \
        && left.subsystem == right.subsystem \
        && left.name == right.name
    end

    def snapshot_params
      exclusively { copy_params(params) }
    end

    def restore_params(new_params)
      exclusively { @params = copy_params(new_params) }
    end

    def replace_params(new_params)
      exclusively { @params = copy_params(new_params) }
    end

    def copy_params(list)
      list.map do |param|
        param.clone.tap { |copy| copy.value = param.value.dup }
      end
    end
  end
end
