module OsCtld
  module Utils::CGroupParams
    def list(groupable)
      ret = []

      groupable.cgparams.each do |p|
        next if opts[:parameters] && !opts[:parameters].include?(p.name)
        next if opts[:subsystem] && !opts[:subsystem].include?(p.subsystem)

        info = p.export
        info.update({
          abs_path: File.join(groupable.abs_cgroup_path(p.subsystem), p.name),
        })
        ret << info
      end

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
          log(:info, :cgroup, "Set #{path}=#{p.value}")

          begin
            File.write(path, p.value.to_s)

          rescue => e
            log(
              :warn,
              :cgroup,
              "Unable to set #{path}=#{p.value}: #{e.message}"
            )
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
  end
end
