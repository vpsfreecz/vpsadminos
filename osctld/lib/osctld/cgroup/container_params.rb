require 'osctld/cgroup/params'

module OsCtld
  class CGroup::ContainerParams < CGroup::Params
    def set(*args)
      owner.exclusively do
        super
        owner.lxc_config.configure_cgparams
      end
    end

    def apply(keep_going: false)
      super

      if owner.running?
        params.each do |p|
          path = File.join(
            yield(p.subsystem),
            'user-owned',
            "lxc.payload.#{owner.id}",
            p.name,
          )

          begin
            CGroup.set_param(path, p.value)

          rescue CGroupFileNotFound
            next
          end
        end
      end
    end
  end
end
