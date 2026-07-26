require 'osctld/commands/base'
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

      if opts[:only_cpuset]
        return apply_cpuset_hierarchy(grp)
      end

      unless opts[:skip_cpuset]
        ret = apply_cpuset_hierarchy(grp, recover: true)
        return ret unless ret[:status]
      end

      grp.groups_in_path.each do |g|
        ret = do_apply(g, force)
        return ret unless ret[:status]
      end

      ok
    end

    protected

    def apply_cpuset_hierarchy(grp, recover: false)
      configured = grp.groups_in_path.select do |group|
        group_cpuset_configured?(group)
      end
      return ok if configured.empty?

      anchor = configured.first
      affected = [anchor, *anchor.descendants]
      tainted = affected.select(&:cgroup_policy_tainted?)
      if tainted.any? && !recover
        return error(
          "group cgroup policy is quarantined at #{tainted.first.name}; " \
          'run a full group cgroup parameter apply first'
        )
      end
      outside_path = tainted - grp.groups_in_path
      if outside_path.any?
        return error(
          "group cgroup policy is quarantined at #{outside_path.first.name}; " \
          'apply that exact group before changing its ancestor policy'
        )
      end

      policy = CGroup::GroupCpusetPolicy.new(anchor)
      return ok if policy.applied?

      manipulate(affected, lifecycle: :policy_update) do
        current_taint = affected.select(&:cgroup_policy_tainted?)
        if current_taint.any? && !recover
          next error(
            'group cgroup policy is quarantined at ' \
            "#{current_taint.first.name}; " \
            'run a full group cgroup parameter apply first'
          )
        end
        outside_path = current_taint - grp.groups_in_path
        if outside_path.any?
          next error(
            'group cgroup policy is quarantined at ' \
            "#{outside_path.first.name}; apply that exact group before " \
            'changing its ancestor policy'
          )
        end
        anchor_tainted = anchor.cgroup_policy_tainted?

        with_group_cpuset_guard(
          anchor,
          write: true,
          rollback_guaranteed: true,
          recovery: anchor_tainted,
          clear_on_success: !anchor_tainted
        ) do
          CGroup::GroupCpusetPolicy.new(anchor).apply
          ok
        end
      end
    rescue CGroup::CpusetPolicy::Error => e
      error(e.message)
    end

    def do_apply(grp, force)
      log(:info, grp, "Configuring group '#{grp.path}'")
      apply(
        grp,
        force:,
        cpuset: !opts[:skip_cpuset],
        only_cpuset: opts[:only_cpuset] == true
      )
    end
  end
end
