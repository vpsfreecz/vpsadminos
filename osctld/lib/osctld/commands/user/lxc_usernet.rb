module OsCtld
  class Commands::User::LxcUsernet < Commands::Base
    handle :user_lxc_usernet

    LXC_USERNET = '/etc/lxc/lxc-usernet'

    def execute
      f = File.open("#{LXC_USERNET}.new", 'w')

      net_cnt = 0
      ContainerList.get { |cts| cts.each { |ct| net_cnt += ct.netifs.count } }

      UserList.get do |users|
        users.each do |u|
          # TODO: we need to investigate why it's not enough to set the number
          # of allowed veths to the number of user's containers, but why it
          # has to be the total number of containers.
          f.write("#{u.username} veth none #{net_cnt}\n")
        end
      end

      f.close
      File.rename("#{LXC_USERNET}.new", LXC_USERNET)

      ok
    end
  end
end
