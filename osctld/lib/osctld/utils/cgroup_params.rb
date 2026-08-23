module OsCtld
  module Utils::CGroupParams
    # @param groupable [Group, Container]
    def list(groupable)
      ret = []
      is_ct = groupable.is_a?(Container)

      if opts[:all]
        if is_ct
          groupable.group.groups_in_path.each do |g|
            ret.concat(info(g))
          end

        else
          groupable.groups_in_path.each do |g|
            ret.concat(info(g))
          end
        end
      end

      ret.concat(info(groupable)) if !opts[:all] || is_ct

      ok(ret)
    end

    def set(groupable, opts, apply: true)
      params = groupable.cgparams.import(opts[:parameters])
      transactional = transactional_container_policy?(groupable, params)
      manipulate(
        group_policy_manipulables(groupable, groupable.is_a?(Group)),
        lifecycle: transactional ? :policy_update : false
      ) do
        current_params = groupable.cgparams.each.to_a
        group_policy_recovery =
          groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
        recovery_policies = group_policy_recovery_kinds(groupable)
        cpuset_requested = cpuset_params?(params)
        cpu_requested = cpu_bandwidth_params?(params)
        policy_repair_requested = cpuset_requested || cpu_requested
        validate_mutation_recovery_scope!(
          groupable,
          recovery_policies,
          requested: policy_repair_requested,
          cpuset_available:
            (current_params + params).any? { |param| cpuset_param?(param) }
        )
        cpuset_policy =
          groupable.is_a?(Group) && apply && (
            group_set_policy_changed?(
              current_params,
              params,
              append: opts[:append],
              &method(:cpuset_param?)
            ) \
            || (
              cpuset_requested \
              && !group_cpuset_applied?(groupable)
            ) \
            || (
              policy_repair_requested \
              && recovery_policies.include?(:cpuset)
            )
          )
        cpu_policy =
          groupable.is_a?(Group) && apply && (
            group_set_policy_changed?(
              current_params,
              params,
              append: opts[:append],
              &method(:group_cpu_bandwidth_param?)
            ) \
            || (
              cpu_requested \
              && !group_cpu_bandwidth_applied?(groupable)
            ) \
            || (
              policy_repair_requested \
              && recovery_policies.include?(:cpu_bandwidth)
            )
          )
        group_transactional =
          groupable.is_a?(Group) && (cpuset_policy || cpu_policy)
        group_policy_kind = group_policy_kind(
          cpuset: cpuset_policy,
          cpu_bandwidth: cpu_policy
        )
        cpu_resets, cpu_reset_target =
          group_cpu_reset_plan(
            groupable,
            current_params,
            group_params_after_set(
              current_params,
              params,
              append: opts[:append]
            )
          )

        with_group_policy_guard(
          groupable,
          write: group_transactional,
          rollback_guaranteed: group_transactional,
          cleanup_params:
            if group_transactional
              group_new_runtime_params(groupable, params)
            else
              []
            end,
          recovery: group_policy_recovery,
          kind: group_policy_kind,
          residual_mode: group_policy_residual_mode(group_policy_kind),
          policy_anchors:
            mutation_policy_anchors(
              groupable,
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy
            ),
          cpu_bandwidth_resets: cpu_resets.map(&:dump),
          cpu_bandwidth_reset_target: cpu_reset_target
        ) do |policy_containers|
          if group_transactional
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            transaction_opts = {
              append: opts[:append],
              apply:,
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy,
              force_cpu_bandwidth:
                recovery_policies.include?(:cpu_bandwidth),
              policy_containers:
            }
            transaction_opts[:cpu_bandwidth_resets] = cpu_resets \
              unless cpu_resets.empty?
            groupable.cgparams.transactional_set(
              params,
              **transaction_opts
            ) do |subsystem|
              groupable.abs_cgroup_path(subsystem)
            end

          elsif transactional
            groupable.cgparams.transactional_set(
              params,
              append: opts[:append],
              apply:
            ) do |subsystem|
              groupable.abs_apply_cgroup_path(subsystem)
            end

          else
            groupable.cgparams.set(params, append: opts[:append])

            if apply
              ret =
                if groupable.is_a?(Group)
                  apply(
                    groupable,
                    cpuset: false,
                    cpu_bandwidth: false
                  )
                else
                  apply(groupable)
                end
              next ret unless ret[:status]
            end

          end
          ok
        end
      end
    rescue CGroupSubsystemNotFound,
           CGroupParameterNotFound,
           CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def unset(groupable, opts, reset: true, keep_going: false)
      transactional =
        transactional_container_policy_specs?(
          groupable,
          opts[:parameters]
        )
      manipulate(
        group_policy_manipulables(groupable, groupable.is_a?(Group)),
        lifecycle: transactional ? :policy_update : false
      ) do
        current_params = groupable.cgparams.each.to_a
        group_policy_recovery =
          groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
        recovery_policies = group_policy_recovery_kinds(groupable)
        policy_repair_requested =
          cpuset_specs?(opts[:parameters]) \
          || cpu_bandwidth_specs?(opts[:parameters])
        validate_mutation_recovery_scope!(
          groupable,
          recovery_policies,
          requested: policy_repair_requested,
          cpuset_available:
            groupable.cgparams.each.any? { |param| cpuset_param?(param) }
        )
        cpuset_policy =
          groupable.is_a?(Group) && reset && (
            group_unset_policy_changed?(
              groupable,
              opts[:parameters],
              &method(:cpuset_param?)
            ) \
            || (
              policy_repair_requested \
              && recovery_policies.include?(:cpuset)
            )
          )
        cpu_policy =
          groupable.is_a?(Group) && reset && (
            group_unset_policy_changed?(
              groupable,
              opts[:parameters],
              &method(:group_cpu_bandwidth_param?)
            ) \
            || (
              policy_repair_requested \
              && recovery_policies.include?(:cpu_bandwidth)
            )
          )
        group_transactional =
          groupable.is_a?(Group) && (cpuset_policy || cpu_policy)
        group_policy_kind = group_policy_kind(
          cpuset: cpuset_policy,
          cpu_bandwidth: cpu_policy
        )
        staged_params = group_params_after_unset(
          current_params,
          opts[:parameters]
        )
        cpu_resets, cpu_reset_target =
          group_cpu_reset_plan(
            groupable,
            current_params,
            staged_params
          )

        with_group_policy_guard(
          groupable,
          write: group_transactional,
          rollback_guaranteed: group_transactional,
          recovery: group_policy_recovery,
          kind: group_policy_kind,
          residual_mode: group_policy_residual_mode(group_policy_kind),
          policy_anchors:
            mutation_policy_anchors(
              groupable,
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy
            ),
          cpu_bandwidth_resets: cpu_resets.map(&:dump),
          cpu_bandwidth_reset_target: cpu_reset_target
        ) do |policy_containers|
          if group_transactional
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            transaction_opts = {
              reset:,
              keep_going:,
              apply_all: group_policy_recovery,
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy,
              force_cpu_bandwidth:
                recovery_policies.include?(:cpu_bandwidth),
              policy_containers:
            }
            transaction_opts[:cpu_bandwidth_resets] = cpu_resets \
              unless cpu_resets.empty?
            groupable.cgparams.transactional_unset(
              opts[:parameters],
              **transaction_opts
            ) do |subsystem|
              groupable.abs_cgroup_path(subsystem)
            end

          elsif transactional
            groupable.cgparams.transactional_unset(
              opts[:parameters],
              reset:,
              keep_going:
            ) do |subsystem|
              groupable.abs_apply_cgroup_path(subsystem)
            end
          else
            groupable.cgparams.unset(
              opts[:parameters],
              reset:,
              keep_going:
            ) do |subsystem|
              if groupable.respond_to?(:abs_apply_cgroup_path)
                groupable.abs_apply_cgroup_path(subsystem)

              else
                groupable.abs_cgroup_path(subsystem)
              end
            end
          end

          ok
        end
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def apply(
      groupable,
      force: true,
      cpuset: true,
      only_cpuset: false,
      cpu_bandwidth: true,
      group_policy_guarded: nil
    )
      group_policy_recovery =
        groupable.is_a?(Group) \
        && groupable.cgroup_policy_tainted? \
        && !group_policy_guarded
      recovery_policies = group_policy_recovery_kinds(groupable)
      requested_policies = []
      requested_policies << :cpuset if cpuset
      requested_policies << :cpu_bandwidth \
        if cpu_bandwidth && !only_cpuset
      if group_policy_recovery \
          && (
            only_cpuset \
            || (recovery_policies - requested_policies).any?
          )
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy is quarantined; run a full group cgroup ' \
              'parameter apply before starting containers'
      end
      policy_update =
        groupable.is_a?(Container) \
        && groupable.cgparams.detect do |param|
          container_policy_param?(param) \
            && (cpuset || param.name != 'cpuset.cpus')
        end
      group_cpuset_recovery =
        cpuset \
        && group_policy_recovery \
        && recovery_policies.include?(:cpuset) \
        && !group_cpuset_configured?(groupable)
      group_cpuset_apply =
        if cpuset && group_cpuset_configured?(groupable)
          !group_cpuset_applied?(groupable)
        else
          false
        end
      group_cpu_recovery =
        group_policy_recovery \
        && recovery_policies.include?(:cpu_bandwidth)
      group_cpu_apply =
        if cpu_bandwidth \
            && !only_cpuset \
            && group_cpu_bandwidth_configured?(groupable)
          !group_cpu_bandwidth_applied?(groupable)
        else
          false
        end
      group_policy_write =
        group_cpuset_apply \
        || group_cpuset_recovery \
        || group_cpu_apply \
        || group_policy_recovery
      policy_kind = group_policy_kind(
        cpuset: group_cpuset_apply || group_cpuset_recovery,
        cpu_bandwidth: group_cpu_apply || group_cpu_recovery
      )
      apply_code = proc do
        with_group_policy_guard(
          groupable,
          write: group_policy_write,
          rollback_guaranteed: false,
          recovery: group_policy_recovery,
          kind: policy_kind,
          residual_mode: group_policy_residual_mode(policy_kind),
          existing_marker_guard: group_policy_guarded
        ) do |policy_containers|
          apply_path = proc do |subsystem|
            if groupable.respond_to?(:abs_apply_cgroup_path)
              groupable.abs_apply_cgroup_path(subsystem)

            else
              groupable.abs_cgroup_path(subsystem)
            end
          end

          if groupable.is_a?(Container)
            groupable.cgparams.apply(
              keep_going: force,
              cpuset:,
              &apply_path
            )
          else
            recover_group_policy_runtime!(groupable, &apply_path) \
              if group_policy_recovery
            if group_cpuset_recovery
              groupable.cgparams.reset(
                CGroup::Param.new(
                  CGroup.version,
                  'cpuset',
                  'cpuset.cpus',
                  [],
                  false
                ),
                force,
                &apply_path
              )
            end
            groupable.cgparams.apply(
              keep_going: force,
              cpuset: group_cpuset_apply,
              only_cpuset:,
              cpu_bandwidth:
                cpu_bandwidth && (group_cpu_apply || group_cpu_recovery),
              force_cpu_bandwidth: group_cpu_recovery,
              policy_containers:,
              &apply_path
            )
          end

          ok
        end
      end
      if group_policy_guarded
        apply_code.call
      else
        manipulate(
          group_policy_manipulables(groupable, group_policy_write),
          lifecycle: policy_update ? :policy_update : false,
          &apply_code
        )
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def replace(groupable)
      new_params = groupable.cgparams.import(opts[:parameters])
      transactional =
        transactional_container_policy_replace?(groupable, new_params)
      manipulate(
        group_policy_manipulables(groupable, groupable.is_a?(Group)),
        lifecycle: transactional ? :policy_update : false
      ) do
        group_policy_recovery =
          groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
        current_params = groupable.cgparams.each.to_a
        recovery_policies = group_policy_recovery_kinds(groupable)
        policy_repair_requested =
          (current_params + new_params).any? do |param|
            cpuset_param?(param) || group_cpu_bandwidth_param?(param)
          end
        validate_mutation_recovery_scope!(
          groupable,
          recovery_policies,
          requested: policy_repair_requested,
          cpuset_available:
            (current_params + new_params).any? do |param|
              cpuset_param?(param)
            end
        )
        cpuset_policy =
          group_policy_params_changed?(
            current_params,
            new_params,
            &method(:cpuset_param?)
          ) || (
            policy_repair_requested \
            && recovery_policies.include?(:cpuset)
          )
        cpu_policy =
          group_policy_params_changed?(
            current_params,
            new_params,
            &method(:group_cpu_bandwidth_param?)
          ) || (
            policy_repair_requested \
            && recovery_policies.include?(:cpu_bandwidth)
          )
        group_policy_write =
          groupable.is_a?(Group) && (cpuset_policy || cpu_policy)
        group_policy_kind = group_policy_kind(
          cpuset: cpuset_policy,
          cpu_bandwidth: cpu_policy
        )
        cpu_resets, cpu_reset_target =
          group_cpu_reset_plan(
            groupable,
            current_params,
            new_params
          )

        with_group_policy_guard(
          groupable,
          write: group_policy_write,
          rollback_guaranteed: group_policy_write,
          cleanup_params:
            if group_policy_write
              group_new_runtime_params(groupable, new_params)
            else
              []
            end,
          recovery: group_policy_recovery,
          kind: group_policy_kind,
          residual_mode: group_policy_residual_mode(group_policy_kind),
          policy_anchors:
            mutation_policy_anchors(
              groupable,
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy
            ),
          cpu_bandwidth_resets: cpu_resets.map(&:dump),
          cpu_bandwidth_reset_target: cpu_reset_target
        ) do |policy_containers|
          if group_policy_write
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            transaction_opts = {
              cpuset: cpuset_policy,
              cpu_bandwidth: cpu_policy,
              force_cpu_bandwidth:
                recovery_policies.include?(:cpu_bandwidth),
              policy_containers:
            }
            transaction_opts[:cpu_bandwidth_resets] = cpu_resets \
              unless cpu_resets.empty?
            groupable.cgparams.transactional_replace(
              new_params,
              **transaction_opts
            ) do |subsystem|
              groupable.abs_cgroup_path(subsystem)
            end
            ok

          elsif transactional
            groupable.cgparams.transactional_replace(new_params) do |subsystem|
              groupable.abs_apply_cgroup_path(subsystem)
            end
            ok
          else
            groupable.cgparams.replace(new_params) do |subsystem|
              if groupable.respond_to?(:abs_apply_cgroup_path)
                groupable.abs_apply_cgroup_path(subsystem)

              else
                groupable.abs_cgroup_path(subsystem)
              end
            end

            if groupable.is_a?(Group)
              apply(
                groupable,
                cpuset: false,
                cpu_bandwidth: false
              )
            else
              apply(groupable)
            end
          end
        end
      end
    rescue CGroupSubsystemNotFound,
           CGroupParameterNotFound,
           CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    protected

    def transactional_container_policy?(groupable, params)
      groupable.is_a?(Container) \
        && params.any? { |param| container_policy_param?(param) }
    end

    def group_policy_manipulables(groupable, transactional)
      if transactional && groupable.is_a?(Group)
        group_policy_lock_scope(groupable)
      else
        groupable
      end
    end

    def group_policy_lock_scope(groupable)
      path = group_policy_path(groupable)
      root = path.first || groupable
      descendants =
        if root.respond_to?(:descendants)
          root.descendants
        else
          []
        end

      ([root] + descendants).uniq
    end

    def group_policy_overlap_scope(groupable)
      path = group_policy_path(groupable)
      descendants =
        if groupable.respond_to?(:descendants)
          groupable.descendants
        else
          []
        end

      (path + descendants).uniq
    end

    def group_policy_path(groupable)
      path =
        if groupable.respond_to?(:groups_in_path)
          groupable.groups_in_path
        else
          [groupable]
        end
      path.empty? ? [groupable] : path
    end

    def transactional_container_policy_specs?(groupable, specs)
      groupable.is_a?(Container) \
        && specs.any? do |param|
          container_policy_parameter?(
            param.fetch(:version, CGroup.version),
            param[:parameter]
          )
        end
    end

    def transactional_container_policy_replace?(groupable, params)
      return false unless groupable.is_a?(Container)
      return true if params.any? { |param| container_policy_param?(param) }

      groupable.cgparams.detect { |param| container_policy_param?(param) }
    end

    def container_policy_param?(param)
      container_policy_parameter?(param.version, param.name)
    end

    def container_policy_parameter?(version, name)
      return false unless version == CGroup.version
      return true if name == 'cpuset.cpus'

      if version == 1
        %w[cpu.cfs_period_us cpu.cfs_quota_us].include?(name)
      else
        name == 'cpu.max'
      end
    end

    def group_cpuset_configured?(groupable, additional = [])
      return false unless groupable.is_a?(Group)
      return true if cpuset_params?(additional)

      param = groupable.cgparams.detect do |param|
        param.version == CGroup.version && param.name == 'cpuset.cpus'
      end
      param ? cpuset_param?(param) : false
    end

    def cpuset_param?(param)
      param.version == CGroup.version && param.name == 'cpuset.cpus'
    end

    def group_cpu_bandwidth_configured?(groupable, additional = [])
      return false unless groupable.is_a?(Group)
      return true if cpu_bandwidth_params?(additional)

      param = groupable.cgparams.detect do |param|
        group_cpu_bandwidth_param?(param)
      end
      param ? group_cpu_bandwidth_param?(param) : false
    end

    def group_cpuset_applied?(groupable)
      return false if groupable.cgroup_policy_tainted?

      param = groupable.cgparams.detect do |item|
        item.version == CGroup.version && item.name == 'cpuset.cpus'
      end
      return false unless param

      cgroup_path = groupable.abs_cgroup_path(param.subsystem)
      explicit = File.read(File.join(cgroup_path, param.name)).strip
      return false if explicit.empty?

      current = CGroup::CpusetPolicy.read_effective_mask(cgroup_path)
      target = OsCtl::Lib::CpuMask.new(param.value.last.to_s).to_s
      requested = OsCtl::Lib::CpuMask.new(explicit).to_s
      requested == target && current == target
    rescue CGroup::CpusetPolicy::Error, SystemCallError, ArgumentError
      false
    end

    def group_cpu_bandwidth_applied?(groupable)
      return false if groupable.cgroup_policy_tainted?

      CGroup::GroupCpuBandwidthPolicy.new(groupable).applied?
    rescue CGroup::CpusetPolicy::Error, SystemCallError, ArgumentError
      false
    end

    def cpuset_params?(params)
      params.any? do |param|
        param.version == CGroup.version && param.name == 'cpuset.cpus'
      end
    end

    def cpuset_specs?(specs)
      specs.any? { |spec| spec[:parameter] == 'cpuset.cpus' }
    end

    def cpu_bandwidth_params?(params)
      params.any? { |param| group_cpu_bandwidth_param?(param) }
    end

    def cpu_bandwidth_specs?(specs)
      specs.any? do |spec|
        container_policy_parameter?(
          spec.fetch(:version, CGroup.version),
          spec[:parameter]
        ) && spec[:parameter] != 'cpuset.cpus'
      end
    end

    def group_cpu_bandwidth_param?(param)
      container_policy_parameter?(param.version, param.name) \
        && param.name != 'cpuset.cpus'
    end

    def group_policy_kind(cpuset:, cpu_bandwidth:)
      return :group_cgroup_policy if cpuset && cpu_bandwidth
      return :group_cpu_bandwidth if cpu_bandwidth

      :group_cpuset
    end

    def group_policy_residual_mode(kind)
      kind == :group_cpu_bandwidth ? :pin : :reject
    end

    def group_policy_recovery_kinds(groupable)
      return [] unless groupable.is_a?(Group)

      state = groupable.cgroup_policy_state
      return [] unless state

      case state.fetch('kind')
      when 'group_cpuset'
        [:cpuset]
      when 'group_cpu_bandwidth'
        [:cpu_bandwidth]
      when 'group_cgroup_params'
        []
      else
        %i[cpuset cpu_bandwidth]
      end
    end

    def validate_mutation_recovery_scope!(
      groupable,
      recovery_policies,
      requested:,
      cpuset_available:
    )
      return unless groupable.is_a?(Group)
      return if recovery_policies.empty? || !requested

      anchors = groupable.cgroup_policy_state&.fetch(
        'policy_anchors',
        {}
      ) || {}
      mismatched = recovery_policies.detect do |controller|
        name = anchors[controller.to_s]
        name && name != groupable.name
      end
      if mismatched
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy recovery uses a different recorded ' \
              "#{mismatched} anchor; run a full group cgroup parameter apply"
      end
      return unless recovery_policies.include?(:cpuset) && !cpuset_available

      raise CGroup::CpusetPolicy::Error,
            'group cpuset recovery has no local configured or reset ' \
            'target; run a full group cgroup parameter apply'
    end

    def mutation_policy_anchors(groupable, cpuset:, cpu_bandwidth:)
      return unless groupable.is_a?(Group)

      {}.tap do |ret|
        ret[:cpuset] = groupable.name if cpuset
        ret[:cpu_bandwidth] = groupable.name if cpu_bandwidth
      end
    end

    def group_policy_params_changed?(before, staged, &block)
      return false unless block

      left = before.select { |param| block.call(param) }
      right = staged.select { |param| block.call(param) }
      return true unless left.length == right.length

      left.any? do |param|
        candidate = right.detect { |item| same_cgroup_param?(param, item) }
        !candidate || candidate.value != param.value
      end
    end

    def group_set_policy_changed?(before, incoming, append:)
      return false unless block_given?

      incoming.any? do |param|
        next false unless yield(param)

        current = before.detect { |item| same_cgroup_param?(item, param) }
        next true unless current

        wanted = append ? current.value + param.value : param.value
        current.value != wanted
      end
    end

    def group_unset_policy_changed?(groupable, specs)
      return false unless groupable.is_a?(Group)
      return false unless block_given?

      imported = specs.map { |spec| CGroup::Param.import(spec) }
      groupable.cgparams.each.any? do |param|
        yield(param) \
          && imported.any? { |candidate| same_cgroup_param?(param, candidate) }
      end
    end

    def same_cgroup_param?(left, right)
      left.version == right.version \
        && left.subsystem == right.subsystem \
        && left.name == right.name
    end

    def group_new_runtime_params(groupable, new_params)
      current = groupable.cgparams.each.to_a

      new_params
        .select { |param| param.version == CGroup.version }
        .reject do |param|
          current.any? do |existing|
            existing.version == param.version \
              && existing.subsystem == param.subsystem \
              && existing.name == param.name
          end
        end
        .map(&:dump)
    end

    def recover_group_policy_runtime!(groupable, &block)
      state = groupable.cgroup_policy_state
      cleanup_params = state && state['cleanup_params']
      unless cleanup_params.is_a?(Array)
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy quarantine has no structured recovery ' \
              'record; remove the group cgroups before clearing it'
      end

      cleanup_params.each do |param_cfg|
        param = CGroup::Param.load(param_cfg)
        next unless param.version == CGroup.version
        next if group_cpu_bandwidth_param?(param)

        groupable.cgparams.reset(param, true, &block)
      end
    end

    def group_cpu_reset_plan(groupable, current, staged)
      return [[], nil] unless groupable.is_a?(Group)

      removed = current.select do |param|
        group_cpu_bandwidth_param?(param) \
          && staged.none? { |candidate| same_cgroup_param?(param, candidate) }
      end
      resets = merge_group_cpu_resets(
        applicable_group_cpu_resets(groupable, current),
        removed
      )
      return [[], nil] if resets.empty?

      [resets, group_cpu_fingerprint(staged)]
    end

    def applicable_group_cpu_resets(groupable, current = nil)
      state = groupable.cgroup_policy_state
      resets = state&.fetch('cpu_bandwidth_resets', nil)
      target = state&.fetch('cpu_bandwidth_reset_target', nil)
      return [] unless resets.is_a?(Array) && target.is_a?(Array)

      # The marker is published before staged configuration is persisted. A
      # matching fingerprint proves that recovery observed the post-commit
      # configuration; a mismatch means that the crash happened before the
      # commit, or that compensation restored the previous configuration.
      current ||= groupable.cgparams.each.to_a
      return [] unless group_cpu_fingerprint(current) == target

      resets.map { |param| CGroup::Param.load(param) }
    end

    def merge_group_cpu_resets(*lists)
      lists
        .flatten
        .select { |param| group_cpu_bandwidth_param?(param) }
        .uniq { |param| [param.version, param.subsystem, param.name] }
    end

    def group_cpu_fingerprint(params)
      params
        .select(&:persistent)
        .select { |param| group_cpu_bandwidth_param?(param) }
        .sort_by { |param| [param.version, param.subsystem, param.name] }
        .map(&:dump)
    end

    def group_params_after_set(current, incoming, append:)
      staged = copy_group_params(current)

      incoming.each do |param|
        existing = staged.index do |candidate|
          same_cgroup_param?(candidate, param)
        end
        copy = copy_group_param(param)
        if existing
          if append
            copy.value = staged.fetch(existing).value + copy.value
          end
          staged[existing] = copy
        else
          staged << copy
        end
      end

      staged
    end

    def group_params_after_unset(current, specs)
      removed = specs.map { |spec| CGroup::Param.import(spec) }

      current.reject do |param|
        removed.any? { |candidate| same_cgroup_param?(param, candidate) }
      end
    end

    def copy_group_params(params)
      params.map { |param| copy_group_param(param) }
    end

    def copy_group_param(param)
      param.clone.tap { |copy| copy.value = param.value.dup }
    end

    def merge_group_cleanup_params(*lists)
      lists.compact.flatten(1).uniq do |param|
        [
          param['version'],
          param['subsystem'],
          param['name']
        ]
      end
    end

    def with_group_policy_guard(
      groupable,
      write:,
      rollback_guaranteed: false,
      cleanup_params: [],
      recovery: false,
      clear_on_success: true,
      kind: :group_cpuset,
      residual_mode: :reject,
      policy_anchors: nil,
      cpu_bandwidth_resets: nil,
      cpu_bandwidth_reset_target: nil,
      existing_marker_guard: nil
    )
      return yield unless groupable.is_a?(Group)

      leases = []
      operation_error = nil
      original_group_state = groupable.cgroup_policy_state
      overlapping_markers =
        group_policy_overlap_scope(groupable).select do |group|
          group != groupable && group.cgroup_policy_tainted?
        end
      unless write
        if original_group_state && !existing_marker_guard.equal?(groupable)
          raise CGroup::CpusetPolicy::Error,
                'group cgroup policy is quarantined; run a full group ' \
                'cgroup parameter apply first'
        end
        if overlapping_markers.any?
          blocked = overlapping_markers.first
          raise CGroup::CpusetPolicy::Error,
                "group cgroup policy is quarantined at #{blocked.name}; " \
                'apply that exact group before changing an overlapping ' \
                'policy'
        end
        return yield
      end

      if original_group_state && !recovery
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy is quarantined; run a full group cgroup ' \
              'parameter apply first'
      end
      if overlapping_markers.any?
        blocked = overlapping_markers.first
        raise CGroup::CpusetPolicy::Error,
              "group cgroup policy is quarantined at #{blocked.name}; " \
              'apply that exact group before changing an overlapping policy'
      end
      if recovery \
          && !original_group_state['cleanup_params'].is_a?(Array)
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy quarantine has no structured recovery ' \
              'record; remove the group cgroups before clearing it'
      end
      marker_cleanup_params =
        if recovery
          merge_group_cleanup_params(
            original_group_state['cleanup_params'],
            cleanup_params
          )
        else
          cleanup_params
        end
      marker_policy_anchors =
        if recovery
          original_group_state['policy_anchors'] || policy_anchors
        else
          policy_anchors
        end
      marker_cpu_resets =
        if recovery && cpu_bandwidth_resets.nil?
          original_group_state['cpu_bandwidth_resets']
        else
          cpu_bandwidth_resets
        end
      marker_cpu_reset_target =
        if recovery && cpu_bandwidth_resets.nil?
          original_group_state['cpu_bandwidth_reset_target']
        else
          cpu_bandwidth_reset_target
        end
      marker_started = false
      runtime_apply_started = false

      begin
        # Publish admission fencing before taking the membership snapshot.
        # Containers registered while leases are acquired will inherit this
        # marker and cannot start until this transaction settles.
        marker_args = {
          kind:,
          cleanup_params: marker_cleanup_params
        }
        marker_args[:policy_anchors] = marker_policy_anchors \
          if marker_policy_anchors
        if marker_cpu_resets && !marker_cpu_resets.empty?
          marker_args[:cpu_bandwidth_resets] = marker_cpu_resets
          marker_args[:cpu_bandwidth_reset_target] =
            marker_cpu_reset_target
        end
        groupable.begin_cgroup_policy_update!(**marker_args)
        marker_started = true
        containers = groupable.containers_in_subtree.sort_by(&:ident)

        containers.each do |ct|
          if residual_mode == :reject && ct.lifecycle.residuals.any?
            raise CGroup::CpusetPolicy::Error,
                  "cannot change #{group_policy_label(kind)} while " \
                  'descendant container ' \
                  "#{ct.ident} has residual runtime cgroups; use explicit " \
                  'recovery first'
          end

          if ct.lifecycle.policy_tainted?
            raise CGroup::CpusetPolicy::Error,
                  "cannot change #{group_policy_label(kind)} while " \
                  'descendant container ' \
                  "#{ct.ident} has a tainted cgroup policy; use explicit " \
                  'recovery first'
          end

          lease = Daemon.get.with_lifecycle_admission do
            ct.lifecycle.begin_parent_policy_update(
              kind:,
              allow_residuals: residual_mode == :pin
            )
          end
          unless lease
            raise CGroup::CpusetPolicy::Error,
                  "cannot change #{group_policy_label(kind)} while " \
                  'descendant container ' \
                  "#{ct.ident} has an active lifecycle, policy, or recovery " \
                  'operation'
          end

          leases << [ct, lease]
        end

        # Cgroup path creation is already a kernel-side change.
        runtime_apply_started = true
        result = CGroup.sync do
          yield(containers)
        end
        if clear_on_success
          groupable.clear_cgroup_policy_state!
        else
          groupable.restore_cgroup_policy_state!(original_group_state)
        end
        result
      rescue StandardError => e
        operation_error = e
        if marker_started
          begin
            if runtime_apply_started
              rollback_error =
                if e.respond_to?(:rollback_error)
                  e.rollback_error
                end
              if rollback_error || !rollback_guaranteed
                error_cleanup_params =
                  if e.respond_to?(:cleanup_params)
                    e.cleanup_params
                  else
                    []
                  end
                groupable.taint_cgroup_policy!(
                  kind:,
                  error: e.message,
                  rollback_error:
                    rollback_error&.message \
                    || 'runtime group policy apply did not complete',
                  cleanup_params: merge_group_cleanup_params(
                    marker_cleanup_params,
                    error_cleanup_params
                  )
                )
              else
                groupable.restore_cgroup_policy_state!(
                  original_group_state
                )
              end
            else
              groupable.restore_cgroup_policy_state!(
                original_group_state
              )
            end
          rescue StandardError => marker_error
            operation_error = CGroup::CpusetPolicy::Error.new(
              "#{e.message}; unable to persist group policy quarantine: " \
              "#{marker_error.message}",
              rollback_error: marker_error
            )
          end
        end
        raise operation_error
      ensure
        leases.reverse_each do |ct, lease|
          finish_group_policy_fence(
            ct,
            lease,
            error: operation_error
          )
        end
      end
    end

    def finish_group_policy_fence(ct, lease, error:)
      completion = ct.lifecycle.finish_parent_policy_update(
        lease.id,
        error: error&.message
      )
      return unless completion&.effect_id

      run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
        conf.run_id == completion.run_id
      end

      if run_conf
        require 'osctld/container/lifecycle_finalizer'
        Container::LifecycleFinalizer.spawn(
          ct,
          run_conf,
          completion.effect_id
        )
      else
        ct.lifecycle.fail_cleanup(
          completion.run_id,
          completion.effect_id,
          'exact run configuration is missing'
        )
      end
    end

    def group_policy_label(kind)
      case kind
      when :group_cpuset
        'group cpuset'
      when :group_cpu_bandwidth
        'group CPU bandwidth'
      when :group_cgroup_params
        'group cgroup parameters'
      else
        'group cgroup policy'
      end
    end

    def info(groupable)
      ret = []

      groupable.cgparams.each do |p|
        next if opts[:version] && p.version != opts[:version]
        next if opts[:parameters] && !opts[:parameters].include?(p.name)
        next if opts[:subsystem] && !opts[:subsystem].include?(p.subsystem)

        info = p.export
        info[:abs_path] = File.join(groupable.abs_cgroup_path(p.subsystem), p.name)
        info[:group] = groupable.is_a?(Group) ? groupable.name : nil

        ret << info
      end

      ret
    end
  end
end
