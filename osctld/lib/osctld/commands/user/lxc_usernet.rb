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
        bridges = {}
        routed_cnt = 0

        # Count interfaces per type
        cts = user_cts[u]
        next if cts.nil?

        cts.each do |ct|
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
    end
  end
end
