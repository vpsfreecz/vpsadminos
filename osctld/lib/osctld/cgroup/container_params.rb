require 'osctld/cgroup/params'

module OsCtld
  class CGroup::ContainerParams < CGroup::Params
    def set(*args, **kwargs)
      owner.exclusively do
        super
        owner.lxc_config.configure_cgparams
      end
    end

    def apply(keep_going: false, &)
      super
      return unless owner.running?

      apply_container_params_and_retry(usable_params, keep_going:, &)
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
      apply_container_params_and_retry(tmp_params, keep_going: true) do |subsystem|
        owner.abs_apply_cgroup_path(subsystem)
      end

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
      apply_container_params_and_retry([new_param], keep_going: true) do |subsystem|
        owner.abs_apply_cgroup_path(subsystem)
      end

      nil
    end

    def apply_container_params(param_list, keep_going: false)
      failed = []

      param_list.each do |p|
        path = File.join(
          yield(p.subsystem),
          'user-owned',
          "lxc.payload.#{owner.id}",
          p.name
        )

        begin
          failed << p unless CGroup.set_param(path, p.value)
        rescue CGroupFileNotFound
          next
        end
      end

      failed
    end

    def apply_container_params_and_retry(param_list, keep_going: false, &)
      failed = apply_container_params(
        param_list,
        keep_going:,
        &
      ).select { |p| p.name.start_with?('memory.') }

      return unless failed.any?

      apply_container_params(failed, keep_going:, &)
    end
  end
end
