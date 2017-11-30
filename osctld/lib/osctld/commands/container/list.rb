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
        user_cts[ct.user] ||= []
        user_cts[ct.user] << ct.id

        ct_infos[ct.id] = {
          id: ct.id,
          user: ct.user.name,
          dataset: ct.dataset,
          rootfs: ct.rootfs,
        }
      end

      user_cts.each do |user, ctids|
        ret = ct_control(user, :ct_status, ids: ctids)
        next if ret[:status] != 'ok'

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
