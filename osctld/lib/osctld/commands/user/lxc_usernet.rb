module OsCtld
  class Commands::User::LxcUsernet < Commands::Base
    handle :user_lxc_usernet

    LXC_USERNET = '/etc/lxc/lxc-usernet'

    def execute
      f = File.open("#{LXC_USERNET}.new", 'w')

      DB::Users.get.each do |u|
        bridges = {}
        routed_cnt = 0

        # Count interfaces per type
        u.containers.each do |ct|
          ct.netifs.each do |netif|
            case netif.type
            when :bridge
              bridges[netif.link] ||= 0
              bridges[netif.link] += 1

            when :routed
              routed_cnt += 1

            else
              fail "unknown netif type '#{netif.type}'"
            end
          end
        end

        # Write results
        f.write("#{u.sysusername} veth none #{routed_cnt}\n")

        bridges.each do |br, n|
          f.write("#{u.sysusername} veth #{br} #{n}\n")
        end
      end

      f.close
      File.rename("#{LXC_USERNET}.new", LXC_USERNET)

      ok
    end
  end
end
