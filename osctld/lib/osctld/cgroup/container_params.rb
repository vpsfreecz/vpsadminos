require 'osctld/cgroup/params'

module OsCtld
  class CGroup::ContainerParams < CGroup::Params
    def set(*args, **kwargs)
      owner.exclusively do
        super
        owner.lxc_config.configure_cgparams
      end
    end

    def apply(keep_going: false, &block)
      super
      return unless owner.running?

      apply_container_params_and_retry(usable_params, keep_going: keep_going, &block)
    end

    # Temporarily expand container memory by given percentage
    def temporarily_expand_memory(percent: 30)
      return if !CGroup.v1? || !owner.running?

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

    protected
    def apply_container_params(param_list, keep_going: false)
      failed = []

      param_list.each do |p|
        path = File.join(
          yield(p.subsystem),
          'user-owned',
          "lxc.payload.#{owner.id}",
          p.name,
        )

        begin
          failed << p unless CGroup.set_param(path, p.value)

        rescue CGroupFileNotFound
          next
        end
      end

      failed
    end

    def apply_container_params_and_retry(param_list, keep_going: false, &block)
      failed = apply_container_params(
        param_list,
        keep_going: keep_going,
        &block
      ).select { |p| p.name.start_with?('memory.') }

      if failed.any?
        apply_container_params(failed, keep_going: keep_going, &block)
      end
    end
  end
end
