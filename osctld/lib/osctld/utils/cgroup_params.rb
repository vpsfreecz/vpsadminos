module OsCtld
  module Utils::CGroupParams
    def list(groupable)
      ret = []
      is_ct = groupable.is_a?(Container)

      if opts[:all]
        if is_ct
          path = groupable.group.path

        else
          path = groupable.path
        end

        each_group_in(groupable.pool, path) do |g|
          ret.concat(info(g))
        end
      end

      ret.concat(info(groupable)) if !opts[:all] || is_ct

      ok(ret)
    end

    def set(groupable, param, apply: true)
      params = groupable.import_cgparams([{
        subsystem: param[:subsystem],
        parameter: param[:parameter],
        value: param[:value],
      }])

      groupable.set(params)

      if apply
        ret = apply(groupable)
        return ret unless ret[:status]
      end

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end

    def unset(groupable, param)
      groupable.unset([{
        subsystem: param[:subsystem],
        parameter: param[:parameter],
      }])

      ok
    end

    def apply(groupable, force: true)
      groupable.cgparams.each do |p|
        path = File.join(groupable.abs_cgroup_path(p.subsystem), p.name)

        if File.exist?(path)
          p.value.each do |v|
            log(:info, :cgroup, "Set #{path}=#{v}")

            begin
              File.write(path, v.to_s)

            rescue => e
              log(
                :warn,
                :cgroup,
                "Unable to set #{path}=#{v}: #{e.message}"
              )
            end
          end

          next
        end

        fail "Unable to set #{path}=#{p.value}: parameter not found" if force
        log(
          :info,
          :cgroup,
          "Skip #{path}, group does not exist and no container is running"
        )
      end

      ok
    end

    protected
    def each_group_in(pool, path)
      yield(DB::Groups.root(pool))

      t = ''

      path.split('/').each do |name|
        t = File.join(t, name)
        t = t[1..-1] if t.start_with?('/')

        g = DB::Groups.by_path(pool, t)
        next unless g

        yield(g)
      end
    end

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
