module OsCtld
  class Commands::Container::List < Commands::Base
    handle :ct_list

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ret = []

      ContainerList.get.each do |ct|
        ct.inclusively do
          ret << {
            id: ct.id,
            user: ct.user.name,
            dataset: ct.dataset,
            rootfs: ct.rootfs,
            distribution: ct.distribution,
            version: ct.version,
            state: ct.state,
            init_pid: ct.init_pid,
            veth: ct.veth,
          }
        end
      end

      ok(ret)
    end
  end
end
