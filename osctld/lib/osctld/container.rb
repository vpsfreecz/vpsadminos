require 'yaml'

module OsCtld
  class Container
    include Lockable
    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    attr_reader :id, :user, :distribution, :version
    attr_accessor :state, :init_pid

    def initialize(id, user_name, load: true)
      init_lock

      @id = id
      @user = UserList.find(user_name) || (raise "user not found")
      @state = :unknown
      @init_pid = nil

      load_config if load
    end

    def configure(distribution, version)
      @distribution = distribution
      @version = version
      @netifs = []
      save_config
    end

    def current_state
      inclusively do
        next(state) if state != :unknown
        ret = ct_control(user, :ct_status, ids: [id])

        if ret[:status]
          state = ret[:output][id.to_sym][:state].to_sym
          state

        else
          :unknown
        end
      end
    end

    def dataset
      ct_ds(@user.name, @id)
    end

    def ctdir
      ct_dir(@user.name, @id)
    end

    def rootfs
      File.join(ctdir, 'private')
    end

    def config_path
      File.join(ctdir, 'ct.yml')
    end

    def lxc_config_path(cfg = 'config')
      File.join(ctdir, cfg.to_s)
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

    # Generate LXC network configuration
    def configure_network
      Template.render_to('ct/network', {
        netifs: @netifs,
      }, lxc_config_path('network'))
    end

    def save_config
      data = {
        'distribution' => distribution,
        'version' => version,
        'net_interfaces' => @netifs.map { |v| v.save },
      }

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(data))
      end

      File.chown(0, 0, config_path)
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

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
    end
  end
end
