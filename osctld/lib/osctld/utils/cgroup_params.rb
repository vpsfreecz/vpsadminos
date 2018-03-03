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

    def set(groupable, param, apply: true)
      params = groupable.cgparams.import([{
        subsystem: param[:subsystem],
        parameter: param[:parameter],
        value: param[:value],
      }])

      groupable.cgparams.set(params, append: param[:append])

      if apply
        ret = apply(groupable)
        return ret unless ret[:status]
      end

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end

    def unset(groupable, param)
      groupable.cgparams.unset([{
        subsystem: param[:subsystem],
        parameter: param[:parameter],
      }])

      ok
    end

    def apply(groupable, force: true)
      groupable.cgparams.apply(keep_going: force) do |subsystem|
        groupable.abs_cgroup_path(subsystem)
      end

      ok
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
