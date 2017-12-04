module OsCtld
  class Commands::User::LxcUsernet < Commands::Base
    handle :user_lxc_usernet

    LXC_USERNET = '/etc/lxc/lxc-usernet'

    def execute
      f = File.open("#{LXC_USERNET}.new", 'w')

      UserList.get do |users|
        users.each do |u|
          ct_cnt = u.containers.count

          f.write("#{u.username} veth none #{ct_cnt}\n")
        end
      end

      f.close
      File.rename("#{LXC_USERNET}.new", LXC_USERNET)

      ok
    end
  end
end
