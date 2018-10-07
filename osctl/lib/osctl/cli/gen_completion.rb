require 'libosctl'

module OsCtl
  class Cli::GenCompletion < Cli::Command
    def bash
      c = OsCtl::Lib::Cli::Completion::Bash.new(Cli::App.get)
      c.shortcuts = %w(ct group healthcheck pool repo user)

      pools = "#{$0} pool ls -H -o name"

      ctids = <<-END
        #{$0} ct ls -H -o pool,id | while read line ; do
          arr=($line)
          echo ${arr[0]}:${arr[1]}
        done
      END

      usernames = <<-END
        #{$0} user ls -H -o pool,name | while read line ; do
          arr=($line)
          echo ${arr[0]}:${arr[1]}
        done
      END

      groupnames = <<-END
        #{$0} group ls -H -o pool,name | while read line ; do
          arr=($line)
          echo ${arr[0]}:${arr[1]}
        done
      END

      repos = <<-END
        #{$0} repository ls -H -o pool,name | while read line ; do
          arr=($line)
          echo ${arr[0]}:${arr[1]}
        done
      END

      tags = 'echo stable latest'

      host_netifs = 'ls -1 /sys/class/net/'

      netif_types = 'echo bridge routed'

      ct_netifs = "#{$0} ct netif ls -H -o name $1"

      ct_ips = "#{$0} ct netif ip ls -H -o addr $1"
      ct_routes = "#{$0} ct netif route ls -H -o addr $1"

      c.opt(cmd: :all, name: :pool, expand: pools)
      c.opt(cmd: :all, name: :ctid, expand: ctids)
      c.opt(cmd: :all, name: :user, expand: usernames)
      c.opt(cmd: :all, name: :group, expand: groupnames)
      c.opt(cmd: :all, name: :repository, expand: repos)
      c.opt(cmd: :all, name: :tag, expand: tags)
      c.opt(cmd: :all, name: :host_netif, expand: host_netifs)
      c.opt(cmd: :all, name: :netif_type, expand: netif_types)

      c.arg(cmd: %i(osctl ct netif), name: :ifname, expand: ct_netifs)
      c.arg(cmd: %i(osctl vps netif), name: :ifname, expand: ct_netifs)
      c.arg(cmd: %i(osctl ct netif ip), name: :addr, expand: ct_ips)
      c.arg(cmd: %i(osctl vps netif ip), name: :addr, expand: ct_ips)
      c.arg(cmd: %i(osctl ct netif route), name: :addr, expand: ct_routes)
      c.arg(cmd: %i(osctl vps netif route), name: :addr, expand: ct_routes)

      c.arg(cmd: :all, name: :pool, expand: pools)
      c.arg(cmd: :all, name: :ctid, expand: ctids)
      c.arg(cmd: :all, name: :user, expand: usernames)
      c.arg(cmd: :all, name: :group, expand: groupnames)
      c.arg(cmd: :all, name: :repository, expand: repos)
      c.arg(cmd: :all, name: :tag, expand: tags)
      c.arg(cmd: :all, name: :host_netif, expand: host_netifs)
      c.arg(cmd: :all, name: :netif_type, expand: netif_types)

      puts c.generate
    end
  end
end
