require 'osctld/commands/base'

module OsCtld
  class Commands::User::LxcUsernet < Commands::Base
    handle :user_lxc_usernet

    LXC_USERNET = '/etc/lxc/lxc-usernet'

    @@mutex = Mutex.new

    def execute
      @@mutex.synchronize do
        generate
      end

      ok
    end

    protected
    def generate
      f = File.open("#{LXC_USERNET}.new", 'w')

      user_cts = {}

      DB::Containers.each do |ct|
        user_cts[ct.user] ||= []
        user_cts[ct.user] << ct
      end

      DB::Users.each do |u|
        # lxc-user-nic counts db entries by owner, not by the linked bridge name,
        # so we use the total number of user's interfaces for each lxc-usernet entry.
        bridges = []
        netif_cnt = 0

        # Count interfaces per type
        cts = user_cts[u]
        next if cts.nil?

        cts.each do |ct|
          ct.netifs.each do |netif|
            case netif.type
            when :bridge
              bridges << netif.link unless bridges.include?(netif.link)
            end

            netif_cnt += 1
          end
        end

        # Write results
        # We're doubling the amount of allowed interfaces, because of unexplained
        # spurious Quota reached messages from lxc-user-nic.
        f.write("#{u.sysusername} veth none #{netif_cnt * 2}\n")

        bridges.each do |br|
          f.write("#{u.sysusername} veth #{br} #{netif_cnt * 2}\n")
        end
      end

      f.close
      File.rename("#{LXC_USERNET}.new", LXC_USERNET)
    end
  end
end
