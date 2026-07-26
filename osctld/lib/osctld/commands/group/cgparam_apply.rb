require 'osctld/commands/base'
require 'osctld/cgroup/group_cpu_bandwidth_policy'
require 'osctld/cgroup/group_cpuset_policy'
require 'osctld/utils/cgroup_params'

module OsCtld
  module Commands
    module Group; end unless const_defined?(:Group, false)
  end

  class Commands::Group::CGParamApply < Commands::Base
    handle :group_cgparam_apply

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      force = grp.any_container_running?
      generic_recovered = false
      if generic_group_policy_recovery?(grp)
        if opts[:only_policies] || opts[:only_cpuset]
          return error(
            'group cgroup parameters are quarantined; run a full group ' \
            'cgroup parameter apply first'
          )
        end

        ret = do_apply(grp, force, guarded: true)
        return ret unless ret[:status]

        generic_recovered = true
      end

      if opts[:only_cpuset]
        return apply_policy_hierarchy(
          grp,
          controllers: [:cpuset],
          recover: false
        )
      end

      controllers = []
      controllers << :cpuset unless opts[:skip_cpuset]
      controllers << :cpu_bandwidth unless opts[:skip_cpu_bandwidth]
      ret = apply_policy_hierarchy(
        grp,
        controllers:,
        recover: true
      )
      return ret unless ret[:status]
      return ok if opts[:only_policies]

      grp.groups_in_path.each do |group|
        next if generic_recovered && group.equal?(grp)

        ret = do_apply(
          group,
          force,
          guarded: controllers.any?
        )
        return ret unless ret[:status]
      end

      ok
    end

    protected

    def apply_policy_hierarchy(grp, controllers:, recover:)
      return ok if controllers.empty?

      initial = group_policy_plan(grp, controllers:, recover:)
      return ok unless initial[:anchor]

      lock_scope = group_policy_lock_scope(initial.fetch(:anchor))
      manipulate(lock_scope, lifecycle: :policy_update) do
        plan = group_policy_plan(grp, controllers:, recover:)
        next ok unless plan[:anchor]

        anchor = plan.fetch(:anchor)
        unless lock_scope.include?(anchor)
          next error(
            'group cgroup policy anchor changed while waiting for its lock; ' \
            'retry the apply'
          )
        end

        recovery_anchor = plan[:recovery_anchor]
        marker_error = group_policy_marker_error(
          grp,
          anchor,
          group_policy_overlap_scope(anchor),
          recovery: !recovery_anchor.nil?
        )
        next error(marker_error) if marker_error

        policies = group_hierarchy_policies(
          plan[:cpuset_anchor],
          plan[:cpu_anchor],
          recovery_anchor:,
          target_group: grp
        )
        needs = group_hierarchy_policy_needs(policies)
        next ok if needs.empty?

        policies[:cpu_bandwidth]&.preflight!
        kind = group_policy_kind(
          cpuset: needs.include?(:cpuset),
          cpu_bandwidth: needs.include?(:cpu_bandwidth)
        )
        anchor_tainted = anchor.cgroup_policy_tainted?
        policy_anchors = group_policy_anchor_record(
          plan[:cpuset_anchor],
          plan[:cpu_anchor],
          needs
        )

        with_group_policy_guard(
          anchor,
          write: true,
          rollback_guaranteed: false,
          recovery: anchor_tainted,
          kind:,
          residual_mode: group_policy_residual_mode(kind),
          policy_anchors:
        ) do |policy_containers|
          if anchor_tainted
            recover_group_policy_runtime!(anchor) do |subsystem|
              anchor.abs_cgroup_path(subsystem)
            end
          end

          fenced_policies = group_hierarchy_policies(
            plan[:cpuset_anchor],
            plan[:cpu_anchor],
            recovery_anchor:,
            target_group: grp,
            containers: policy_containers
          )
          fenced_needs = group_hierarchy_policy_needs(fenced_policies)
          apply_group_hierarchy_policies(
            anchor,
            fenced_policies,
            fenced_needs,
            recovery_anchor:
          )
          ok
        end
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def group_policy_plan(grp, controllers:, recover:)
      marked = grp.groups_in_path.select(&:cgroup_policy_tainted?)
      recovery_anchor =
        if recover
          marked.detect do |group|
            group_policy_recovery_kinds(group).intersect?(controllers)
          end
        end
      recovery_kinds =
        recovery_anchor ? group_policy_recovery_kinds(recovery_anchor) : []
      cpuset_anchor =
        if controllers.include?(:cpuset)
          if recovery_kinds.include?(:cpuset)
            recorded_policy_anchor(recovery_anchor, :cpuset)
          else
            grp.groups_in_path.detect do |group|
              group_cpuset_configured?(group)
            end
          end
        end
      cpu_anchor =
        if controllers.include?(:cpu_bandwidth)
          if recovery_kinds.include?(:cpu_bandwidth)
            recorded_policy_anchor(recovery_anchor, :cpu_bandwidth)
          else
            grp.groups_in_path.detect do |group|
              group_cpu_bandwidth_configured?(group)
            end
          end
        end

      {
        anchor:
          recovery_anchor \
          || highest_group(grp, [cpuset_anchor, cpu_anchor].compact),
        recovery_anchor:,
        cpuset_anchor:,
        cpu_anchor:
      }
    end

    def recorded_policy_anchor(marker, controller)
      state = marker.cgroup_policy_state
      name = state&.dig('policy_anchors', controller.to_s)
      candidates = [marker, *marker.descendants]
      if name
        found = candidates.detect { |group| group.name == name }
        unless found
          raise CGroup::CpusetPolicy::Error,
                "recorded #{controller} policy anchor #{name} is missing"
        end
        return found
      end

      return marker if controller == :cpu_bandwidth
      return marker if group_cpuset_configured?(marker)

      configured = candidates.drop(1).select do |group|
        group_cpuset_configured?(group)
      end
      roots = configured.reject do |group|
        configured.any? do |candidate|
          candidate != group \
            && group.name.start_with?("#{candidate.name}/")
        end
      end
      return roots.first if roots.length == 1
      return marker if roots.empty?

      raise CGroup::CpusetPolicy::Error,
            'legacy combined group policy marker has ambiguous cpuset ' \
            'anchors; recover each configured subtree explicitly'
    end

    def highest_group(grp, groups)
      path = grp.groups_in_path
      groups.min_by { |group| path.index(group) }
    end

    def group_policy_marker_error(grp, anchor, affected, recovery:)
      tainted = affected.select(&:cgroup_policy_tainted?)
      return if tainted.empty?

      if recovery
        if grp != anchor
          return "group cgroup policy is quarantined at #{anchor.name}; " \
                 'apply that exact group before changing a descendant'
        end

        unexpected = tainted.reject { |group| group == anchor }
        if unexpected.any?
          return 'group cgroup policy is quarantined at ' \
                 "#{unexpected.first.name}; apply that exact group before " \
                 'changing its ancestor policy'
        end

        return
      end

      outside_path = tainted - grp.groups_in_path
      if outside_path.any?
        return 'group cgroup policy is quarantined at ' \
               "#{outside_path.first.name}; apply that exact group before " \
               'changing its ancestor policy'
      end

      "group cgroup policy is quarantined at #{tainted.first.name}; " \
        'run a full group cgroup parameter apply first'
    end

    def group_policy_anchor_record(cpuset_anchor, cpu_anchor, needs)
      {}.tap do |ret|
        if needs.include?(:cpuset) && cpuset_anchor
          ret[:cpuset] = cpuset_anchor.name
        end
        if needs.include?(:cpu_bandwidth) && cpu_anchor
          ret[:cpu_bandwidth] = cpu_anchor.name
        end
      end
    end

    def group_hierarchy_policies(
      cpuset_anchor,
      cpu_anchor,
      recovery_anchor:,
      target_group:,
      containers: nil
    )
      policies = {}
      if cpuset_anchor && group_cpuset_configured?(cpuset_anchor)
        policies[:cpuset] = CGroup::GroupCpusetPolicy.new(
          cpuset_anchor,
          reconstruct_to:
            policy_reconstruction_target(
              cpuset_anchor,
              target_group,
              recovery_anchor
            )
        )
      end
      if cpu_anchor
        cpu_opts = {
          reconstruct_to:
            policy_reconstruction_target(
              cpu_anchor,
              target_group,
              recovery_anchor
            ),
          containers:
        }
        if recovery_anchor
          resets = applicable_group_cpu_resets(recovery_anchor)
          cpu_opts[:resets] = resets unless resets.empty?
        end
        policies[:cpu_bandwidth] =
          CGroup::GroupCpuBandwidthPolicy.new(
            cpu_anchor,
            **cpu_opts
          )
      end
      if recovery_anchor
        policies[:recovery] = group_policy_recovery_kinds(recovery_anchor)
      end
      policies
    end

    def policy_reconstruction_target(
      controller_anchor,
      target_group,
      recovery_anchor
    )
      recovery_anchor ? controller_anchor : target_group
    end

    def group_hierarchy_policy_needs(policies)
      recovery = policies.fetch(:recovery, [])
      needs = []
      if policies[:cpu_bandwidth] \
          && (
            recovery.include?(:cpu_bandwidth) \
            || !policies[:cpu_bandwidth].applied?
          )
        needs << :cpu_bandwidth
      end
      if recovery.include?(:cpuset) \
          || (policies[:cpuset] && !policies[:cpuset].applied?)
        needs << :cpuset
      end
      needs
    end

    def apply_group_hierarchy_policies(
      anchor,
      policies,
      needs,
      recovery_anchor:
    )
      result = CGroup::Params::ApplyResult.new

      begin
        if needs.include?(:cpu_bandwidth)
          result.add(policies.fetch(:cpu_bandwidth).apply)
        end
        if needs.include?(:cpuset)
          if policies[:cpuset]
            result.add(policies[:cpuset].apply)
          elsif recovery_anchor
            CGroup.mkpath(
              'cpuset',
              anchor.cgroup_path.split('/'),
              leaf: false
            )
            anchor.cgparams.reset(
              CGroup::Param.new(
                CGroup.version,
                'cpuset',
                'cpuset.cpus',
                [],
                false
              ),
              true
            ) do |subsystem|
              anchor.abs_cgroup_path(subsystem)
            end
          else
            raise CGroup::CpusetPolicy::Error,
                  'group cpuset policy has no configured recovery target'
          end
        end
      rescue StandardError => e
        begin
          result.rollback!
        rescue StandardError => rollback_error
          raise CGroup::CpusetPolicy::Error.new(
            "#{e.message}; rollback failed: #{rollback_error.message}",
            rollback_error:
          )
        end
        raise
      end

      result
    end

    def do_apply(grp, force, guarded: false)
      log(:info, grp, "Configuring group '#{grp.path}'")
      apply_code = proc do
        apply(
          grp,
          force:,
          cpuset: false,
          only_cpuset: false,
          cpu_bandwidth: false,
          group_policy_guarded: guarded ? grp : nil
        )
      end
      return apply_code.call unless guarded

      initial_generic_recovery = generic_group_policy_recovery?(grp)
      return ok unless initial_generic_recovery || group_generic_params?(grp)

      manipulate(
        group_policy_lock_scope(grp),
        lifecycle: :policy_update
      ) do
        generic_recovery = generic_group_policy_recovery?(grp)
        unless generic_recovery || group_generic_params?(grp)
          next ok
        end

        blocked = group_policy_overlap_scope(grp).detect do |group|
          group.cgroup_policy_tainted? \
            && !(generic_recovery && group.equal?(grp))
        end
        if blocked
          next error(
            "group cgroup policy is quarantined at #{blocked.name}; " \
            'recover it before applying generic parameters'
          )
        end

        with_group_policy_guard(
          grp,
          write: true,
          rollback_guaranteed: false,
          recovery: generic_recovery,
          kind: :group_cgroup_params,
          residual_mode: :reject
        ) do
          if generic_recovery
            recover_group_policy_runtime!(grp) do |subsystem|
              grp.abs_cgroup_path(subsystem)
            end
          end

          ret =
            if group_generic_params?(grp)
              apply_code.call
            else
              ok
            end
          unless ret[:status]
            raise CGroup::CpusetPolicy::Error,
                  ret[:message] \
                  || 'unable to apply generic group cgroup parameters'
          end
          ret
        end
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def group_generic_params?(grp)
      grp.cgparams.each.any? do |param|
        param.version == CGroup.version \
          && param.name != 'cpuset.cpus' \
          && !CGroup::CpuBandwidthPolicy::PARAMETERS.include?(param.name)
      end
    end

    def generic_group_policy_recovery?(grp)
      grp.cgroup_policy_state&.fetch('kind', nil) == 'group_cgroup_params'
    end
  end
end
