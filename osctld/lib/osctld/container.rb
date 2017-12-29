require 'yaml'

module OsCtld
  class Container
    include Lockable
    include CGroupParams
    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    attr_reader :id, :user, :group, :distribution, :version
    attr_accessor :state, :init_pid

    def initialize(id, user = nil, group = nil, load: true)
      init_lock

      @id = id
      @user = user
      @group = group
      @state = :unknown
      @init_pid = nil
      @params = []

      load_config if load
    end

    def configure(user, group, distribution, version)
      @user = user
      @group = group
      @distribution = distribution
      @version = version
      @netifs = []
      save_config
    end

    def current_state
      inclusively do
        next(state) if state != :unknown
        ret = ct_control(self, :ct_status, ids: [id])

        if ret[:status]
          state = ret[:output][id.to_sym][:state].to_sym
          state

        else
          :unknown
        end
      end
    end

    def running?
      state == :running
    end

    def dataset
      File.join(OsCtld::CT_DS, id)
    end

    def dir
      "/#{dataset}"
    end

    def lxc_home
      group.userdir(user)
    end

    def lxc_dir
      File.join(lxc_home, id)
    end

    def rootfs
      File.join(dir, 'private')
    end

    def config_path
      File.join('/', OsCtld::CONF_DS, 'ct', "#{id}.yml")
    end

    def lxc_config_path(cfg = 'config')
      File.join(lxc_dir, cfg.to_s)
    end

    def uid_offset
      @user.offset
    end

    def gid_offset
      @user.offset
    end

    def uid_size
      @user.size
    end

    def gid_size
      @user.size
    end

    def hostname
      "ct-#{@id}"
    end

    def netifs
      @netifs.clone
    end

    def netif_at(index)
      @netifs[index]
    end

    def add_netif(netif)
      @netifs << netif
      save_config
    end

    def del_netif(netif)
      @netifs.delete(netif)
      save_config
    end

    def cgroup_path
      File.join(group.full_cgroup_path(user), id)
    end

    def abs_cgroup_path(subsystem)
      File.join(OsCtld::CGROUP_FS, real_subsystem(subsystem), cgroup_path)
    end

    # Generate LXC network configuration
    def configure_network
      Template.render_to('ct/network', {
        netifs: @netifs,
      }, lxc_config_path('network'))
    end

    def save_config
      data = {
        'user' => user.name,
        'group' => group.name,
        'distribution' => distribution,
        'version' => version,
        'net_interfaces' => @netifs.map { |v| v.save },
        'params' => dump_params(params),
      }

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(data))
      end

      File.chown(0, 0, config_path)
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

      @user = UserList.find(cfg['user']) || (raise "user not found")
      @group = GroupList.find(cfg['group']) || (raise "group not found")
      @distribution = cfg['distribution']
      @version = cfg['version']

      i = 0
      @netifs = (cfg['net_interfaces'] || []).map do |v|
        netif = NetInterface.for(v['type'].to_sym).new(self, i)
        netif.load(v)
        netif.setup
        i += 1
        netif
      end

      @params = load_params(cfg['params'])
    end
  end
end
