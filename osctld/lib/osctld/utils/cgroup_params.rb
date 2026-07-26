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
      group_policy_recovery =
        groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
      group_transactional =
        apply && (
          group_cpuset_configured?(groupable, params) \
          || group_policy_recovery
        )
      group_cpuset_write = group_transactional

      transactional = transactional_container_policy?(groupable, params)
      manipulate(
        groupable,
        lifecycle: transactional ? :policy_update : false
      ) do
        with_group_cpuset_guard(
          groupable,
          write: group_cpuset_write,
          rollback_guaranteed: group_transactional,
          cleanup_params:
            if group_transactional
              group_new_runtime_params(groupable, params)
            else
              []
            end,
          recovery: group_policy_recovery
        ) do
          if group_transactional
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            groupable.cgparams.transactional_set(
              params,
              append: opts[:append],
              apply:
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
              ret = apply(groupable)
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
      group_policy_recovery =
        groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
      group_transactional =
        reset && groupable.is_a?(Group) && (
          cpuset_specs?(opts[:parameters]) \
          || group_policy_recovery
        )
      group_cpuset_write = group_transactional
      manipulate(
        groupable,
        lifecycle: transactional ? :policy_update : false
      ) do
        with_group_cpuset_guard(
          groupable,
          write: group_cpuset_write,
          rollback_guaranteed: group_transactional,
          recovery: group_policy_recovery
        ) do
          if group_transactional
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            groupable.cgparams.transactional_unset(
              opts[:parameters],
              reset:,
              keep_going:,
              apply_all: group_policy_recovery
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
      only_cpuset: false
    )
      group_policy_recovery =
        groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
      if group_policy_recovery && (!cpuset || only_cpuset)
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy is quarantined; run a full group cgroup ' \
              'parameter apply before starting containers'
      end
      policy_update =
        cpuset \
        && groupable.is_a?(Container) \
        && groupable.cgparams.detect { |param| param.name == 'cpuset.cpus' }
      group_cpuset_recovery =
        cpuset \
        && group_policy_recovery \
        && !group_cpuset_configured?(groupable)
      group_cpuset_apply =
        if cpuset && group_cpuset_configured?(groupable)
          !group_cpuset_applied?(groupable)
        else
          false
        end
      group_cpuset_write =
        group_cpuset_apply || group_cpuset_recovery || group_policy_recovery
      manipulate(
        groupable,
        lifecycle: policy_update ? :policy_update : false
      ) do
        with_group_cpuset_guard(
          groupable,
          write: group_cpuset_write,
          rollback_guaranteed: false,
          recovery: group_policy_recovery
        ) do
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
              &apply_path
            )
          end

          ok
        end
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def replace(groupable)
      new_params = groupable.cgparams.import(opts[:parameters])
      transactional =
        transactional_container_policy_replace?(groupable, new_params)
      group_policy_recovery =
        groupable.is_a?(Group) && groupable.cgroup_policy_tainted?
      group_cpuset_write =
        group_cpuset_configured?(groupable, new_params) \
        || group_policy_recovery
      manipulate(
        groupable,
        lifecycle: transactional ? :policy_update : false
      ) do
        with_group_cpuset_guard(
          groupable,
          write: group_cpuset_write,
          rollback_guaranteed: group_cpuset_write,
          cleanup_params:
            if group_cpuset_write
              group_new_runtime_params(groupable, new_params)
            else
              []
            end,
          recovery: group_policy_recovery
        ) do
          if group_cpuset_write
            if group_policy_recovery
              recover_group_policy_runtime!(groupable) do |subsystem|
                groupable.abs_cgroup_path(subsystem)
              end
            end
            groupable.cgparams.transactional_replace(new_params) do |subsystem|
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

            apply(groupable)
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
      version == CGroup.version && name == 'cpuset.cpus'
    end

    def group_cpuset_configured?(groupable, additional = [])
      return false unless groupable.is_a?(Group)

      cpuset_params?(additional) || groupable.cgparams.detect do |param|
        param.version == CGroup.version && param.name == 'cpuset.cpus'
      end
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

    def cpuset_params?(params)
      params.any? do |param|
        param.version == CGroup.version && param.name == 'cpuset.cpus'
      end
    end

    def cpuset_specs?(specs)
      specs.any? { |spec| spec[:parameter] == 'cpuset.cpus' }
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

        groupable.cgparams.reset(param, true, &block)
      end
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

    def with_group_cpuset_guard(
      groupable,
      write:,
      rollback_guaranteed: false,
      cleanup_params: [],
      recovery: false,
      clear_on_success: true
    )
      return yield unless write && groupable.is_a?(Group)

      leases = []
      operation_error = nil
      original_group_state = groupable.cgroup_policy_state
      if original_group_state && !recovery
        raise CGroup::CpusetPolicy::Error,
              'group cgroup policy is quarantined; run a full group cgroup ' \
              'parameter apply first'
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
      marker_started = false
      runtime_apply_started = false

      begin
        # Publish admission fencing before taking the membership snapshot.
        # Containers registered while leases are acquired will inherit this
        # marker and cannot start until this transaction settles.
        groupable.begin_cgroup_policy_update!(
          kind: :group_cpuset,
          cleanup_params: marker_cleanup_params
        )
        marker_started = true
        containers = groupable.containers_in_subtree.sort_by(&:ident)

        containers.each do |ct|
          if ct.lifecycle.residuals.any?
            raise CGroup::CpusetPolicy::Error,
                  'cannot change group cpuset while descendant container ' \
                  "#{ct.ident} has residual runtime cgroups; use explicit " \
                  'recovery first'
          end

          if ct.lifecycle.policy_tainted?
            raise CGroup::CpusetPolicy::Error,
                  'cannot change group cpuset while descendant container ' \
                  "#{ct.ident} has a tainted cgroup policy; use explicit " \
                  'recovery first'
          end

          lease = ct.lifecycle.begin_parent_policy_update(
            kind: :group_cpuset
          )
          unless lease
            raise CGroup::CpusetPolicy::Error,
                  'cannot change group cpuset while descendant container ' \
                  "#{ct.ident} has an active lifecycle, policy, or recovery " \
                  'operation'
          end

          leases << [ct, lease]
        end

        # Cgroup path creation is already a kernel-side change.
        runtime_apply_started = true
        result = CGroup.sync do
          if recovery
            CGroup.mkpath_all(
              groupable.cgroup_path.split('/'),
              leaf: false
            )
          else
            CGroup.mkpath(
              'cpuset',
              groupable.cgroup_path.split('/'),
              leaf: false
            )
          end
          yield
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
                  kind: :group_cpuset,
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
          finish_group_cpuset_fence(
            ct,
            lease,
            error: operation_error
          )
        end
      end
    end

    def finish_group_cpuset_fence(ct, lease, error:)
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
