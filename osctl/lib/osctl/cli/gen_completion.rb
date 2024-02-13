require 'libosctl'

module OsCtl
  class Cli::GenCompletion < Cli::Command
    def bash
      c = OsCtl::Lib::Cli::Completion::Bash.new(Cli::App.get)
      c.shortcuts = %w[ct group healthcheck id-range pool repo user]

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

      id_ranges = <<-END
        #{$0} id-range ls -H -o pool,name | while read line ; do
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
      ct_datasets = "#{$0} ct dataset ls -H -o name $1"

      zfs_pools = 'zpool list -H -o name'
      zfs_datasets = 'zfs list -Hr -o name'

      all_cgparams = <<-END
        for subsys in `find /sys/fs/cgroup -maxdepth 1 -type d` ; do
          find "$subsys/osctl" -maxdepth 1 -type f -printf "%f\\n" 2> /dev/null \\
            | grep -v -e '^cgroup\\.' -e '^devices\\.' -e '^cpuacct\\.' \\
            | grep '\\.'
        done
      END

      ct_cgparams = "#{$0} ct cgparams ls -H -o parameter $1"
      group_cgparams = "#{$0} group cgparams ls -H -o parameter $1"

      c.opt(cmd: %i[osctl pool install], name: :dataset, expand: zfs_datasets)

      c.opt(cmd: :all, name: :pool, expand: pools)
      c.opt(cmd: :all, name: :ctid, expand: ctids)
      c.opt(cmd: :all, name: :user, expand: usernames)
      c.opt(cmd: :all, name: :group, expand: groupnames)
      c.opt(cmd: :all, name: :repository, expand: repos)
      c.opt(cmd: :all, name: :'id-range', expand: id_ranges)
      c.opt(cmd: :all, name: :tag, expand: tags)
      c.opt(cmd: :all, name: :host_netif, expand: host_netifs)
      c.opt(cmd: :all, name: :netif_type, expand: netif_types)

      # Do not suggest existing names when creating new cts/users/...
      c.arg(cmd: %i[osctl pool install], name: :pool, expand: zfs_pools)
      c.arg(cmd: %i[osctl pool import], name: :pool, expand: zfs_pools)
      c.arg(cmd: %i[osctl ct new], name: :ctid, expand: '')
      c.arg(cmd: %i[osctl vps new], name: :ctid, expand: '')
      c.arg(cmd: %i[osctl ct netif new], name: :ifname, expand: '')
      c.arg(cmd: %i[osctl vps netif new], name: :ifname, expand: '')
      c.arg(cmd: %i[osctl ct netif ip add], name: :addr, expand: '')
      c.arg(cmd: %i[osctl vps netif ip add], name: :addr, expand: '')
      c.arg(cmd: %i[osctl user new], name: :user, expand: '')
      c.arg(cmd: %i[osctl repo add], name: :repository, expand: '')
      c.arg(cmd: %i[osctl id-range new], name: :'id-range', expand: '')

      c.arg(cmd: %i[osctl ct dataset], name: :dataset, expand: ct_datasets)
      c.arg(cmd: %i[osctl vps dataset], name: :dataset, expand: ct_datasets)
      c.arg(cmd: %i[osctl ct mounts], name: :dataset, expand: ct_datasets)
      c.arg(cmd: %i[osctl ct netif], name: :ifname, expand: ct_netifs)
      c.arg(cmd: %i[osctl vps netif], name: :ifname, expand: ct_netifs)
      c.arg(cmd: %i[osctl ct netif ip], name: :addr, expand: ct_ips)
      c.arg(cmd: %i[osctl vps netif ip], name: :addr, expand: ct_ips)
      c.arg(cmd: %i[osctl ct netif route], name: :addr, expand: ct_routes)
      c.arg(cmd: %i[osctl vps netif route], name: :addr, expand: ct_routes)

      c.arg(cmd: %i[osctl ct cgparams set], name: :parameter, expand: all_cgparams)
      c.arg(cmd: %i[osctl ct cgparams unset], name: :parameter, expand: ct_cgparams)
      c.arg(cmd: %i[osctl vps cgparams set], name: :parameter, expand: all_cgparams)
      c.arg(cmd: %i[osctl vps cgparams unset], name: :parameter, expand: ct_cgparams)
      c.arg(cmd: %i[osctl group cgparams set], name: :parameter, expand: all_cgparams)
      c.arg(cmd: %i[osctl group cgparams unset], name: :parameter, expand: group_cgparams)

      c.arg(cmd: :all, name: :pool, expand: pools)
      c.arg(cmd: :all, name: :ctid, expand: ctids)
      c.arg(cmd: :all, name: :user, expand: usernames)
      c.arg(cmd: :all, name: :group, expand: groupnames)
      c.arg(cmd: :all, name: :repository, expand: repos)
      c.arg(cmd: :all, name: :'id-range', expand: repos)
      c.arg(cmd: :all, name: :tag, expand: tags)
      c.arg(cmd: :all, name: :host_netif, expand: host_netifs)
      c.arg(cmd: :all, name: :netif_type, expand: netif_types)

      puts c.generate
    end
  end
end
