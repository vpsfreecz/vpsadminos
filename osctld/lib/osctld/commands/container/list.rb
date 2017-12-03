module OsCtld
  class Commands::Container::List < Commands::Base
    handle :ct_list

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      user_cts = {}
      ct_infos = {}

      ContainerList.get.each do |ct|
        ct.lock(:inclusive)

        user_cts[ct.user] ||= []
        user_cts[ct.user] << ct

        ct_infos[ct.id] = {
          id: ct.id,
          user: ct.user.name,
          dataset: ct.dataset,
          rootfs: ct.rootfs,
        }
      end

      user_cts.each do |user, cts|
        ret = ct_control(user, :ct_status, ids: cts.map { |ct| ct.id })
        cts.each { |ct| ct.unlock(:inclusive) }
        next unless ret[:status]

        ret[:output].each do |ctid, info|
          ct_infos[ctid.to_s].update({
            state: info[:state].to_sym,
            init_pid: info[:init_pid],
          })
        end
      end

      ok(ct_infos.map { |_ctid, info| info })
    end
  end
end
