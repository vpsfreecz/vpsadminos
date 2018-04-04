module OsCtld
  class Commands::User::LxcUsernet < Commands::Base
    handle :user_lxc_usernet

    LXC_USERNET = '/etc/lxc/lxc-usernet'

    def execute
      f = File.open("#{LXC_USERNET}.new", 'w')

      net_cnt = 0
      DB::Containers.get { |cts| cts.each { |ct| net_cnt += ct.netifs.count } }

      DB::Users.get.each do |u|
        # TODO: we need to investigate why it's not enough to set the number
        # of allowed veths to the number of user's container's interfaces, but
        # why it has to be the total number interfaces from _all_ containers.

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
        f.write("#{u.sysusername} veth none #{net_cnt}\n") # TODO: use routed_cnt

        bridges.each do |br, n|
          f.write("#{u.sysusername} veth #{br} #{net_cnt}\n") # TODO: use n
        end
      end

      f.close
      File.rename("#{LXC_USERNET}.new", LXC_USERNET)

      ok
    end
  end
end
