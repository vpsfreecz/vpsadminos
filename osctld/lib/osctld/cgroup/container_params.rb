require 'osctld/cgroup/params'

module OsCtld
  class CGroup::ContainerParams < CGroup::Params
    def set(*args)
      owner.exclusively do
        super
        owner.lxc_config.configure_cgparams
      end
    end

    def apply(keep_going: false, &block)
      super
      return unless owner.running?

      failed = apply_container_params(
        params,
        keep_going: keep_going,
        &block
      ).select { |p| p.name.start_with?('memory.') }

      if failed.any?
        apply_container_params(failed, keep_going: keep_going, &block)
      end
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
  end
end
