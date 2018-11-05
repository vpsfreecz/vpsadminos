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

      manipulate(groupable) do
        groupable.cgparams.set(params, append: opts[:append])

        if apply
          ret = apply(groupable)
          return ret unless ret[:status]
        end

        ok
      end

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end

    def unset(groupable, opts, reset: true, keep_going: false)
      manipulate(groupable) do
        groupable.cgparams.unset(
          opts[:parameters],
          reset: reset,
          keep_going: keep_going
        ) do |subsystem|
          if groupable.respond_to?(:abs_apply_cgroup_path)
            groupable.abs_apply_cgroup_path(subsystem)

          else
            groupable.abs_cgroup_path(subsystem)
          end
        end

        ok
      end
    end

    def apply(groupable, force: true)
      manipulate(groupable) do
        groupable.cgparams.apply(keep_going: force) do |subsystem|
          if groupable.respond_to?(:abs_apply_cgroup_path)
            groupable.abs_apply_cgroup_path(subsystem)

          else
            groupable.abs_cgroup_path(subsystem)
          end
        end

        ok
      end
    end

    def replace(groupable)
      manipulate(groupable) do
        groupable.cgparams.replace(
          groupable.cgparams.import(opts[:parameters])
        ) do |subsystem|
          if groupable.respond_to?(:abs_apply_cgroup_path)
            groupable.abs_apply_cgroup_path(subsystem)

          else
            groupable.abs_cgroup_path(subsystem)
          end
        end

        apply(groupable)
      end

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end

    protected
    def info(groupable)
      ret = []

      groupable.cgparams.each do |p|
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
