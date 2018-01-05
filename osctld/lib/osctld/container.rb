require 'yaml'

module OsCtld
  class Container
    include Lockable
    include CGroup::Params
    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    attr_reader :pool, :id, :user, :group, :distribution, :version, :nesting,
      :prlimits
    attr_accessor :state, :init_pid

    def initialize(pool, id, user = nil, group = nil, load: true)
      init_lock

      @pool = pool
      @id = id
      @user = user
      @group = group
      @state = :unknown
      @init_pid = nil
      @cgparams = []
      @prlimits = []
      @nesting = false

      load_config if load
    end

    def configure(user, group, distribution, version)
      @user = user
      @group = group
      @distribution = distribution
      @version = version
      @netifs = []
      @nesting = false
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
      File.join(pool.ct_ds, id)
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
      File.join(pool.conf_path, 'ct', "#{id}.yml")
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
      File.join(CGroup::FS, CGroup.real_subsystem(subsystem), cgroup_path)
    end

    def set(opts)
      opts.each do |k, v|
        case k
        when :nesting
          @nesting = v
        end
      end

      save_config
      configure_base
    end

    def prlimit_set(name, soft, hard)
      exclusively do
        limit = @prlimits.detect { |v| v.name == name }

        if limit
          limit.set(soft, hard)

        else
          @prlimits << PrLimit.new(name, soft, hard)
        end
      end

      save_config
      configure_lxc
    end

    def prlimit_unset(name)
      exclusively do
        limit = @prlimits.detect { |v| v.name == name }
        next unless limit
        @prlimits.delete(limit)
      end

      save_config
      configure_prlimits
    end

    def configure_lxc
      configure_base
      configure_prlimits
      configure_network
    end

    def configure_base
      Template.render_to('ct/config', {
        distribution: distribution,
        ct: self,
        hook_start_host: OsCtld::hook_run('ct-start'),
      }, lxc_config_path)
    end

    def configure_prlimits
      Template.render_to('ct/prlimits', {
        prlimits: prlimits,
      }, lxc_config_path('prlimits'))
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
        'cgparams' => dump_cgparams(cgparams),
        'prlimits' => prlimits.map(&:dump),
        'nesting' => nesting,
      }

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(data))
      end

      File.chown(0, 0, config_path)
    end

    def log_type
      "ct=#{pool.name}:#{id}"
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

      @user = DB::Users.find(cfg['user']) || (raise "user not found")
      @group = DB::Groups.find(cfg['group']) || (raise "group not found")
      @distribution = cfg['distribution']
      @version = cfg['version']
      @nesting = cfg['nesting'] || false

      i = 0
      @netifs = (cfg['net_interfaces'] || []).map do |v|
        netif = NetInterface.for(v['type'].to_sym).new(self, i)
        netif.load(v)
        netif.setup
        i += 1
        netif
      end

      @cgparams = load_cgparams(cfg['cgparams'])
      @prlimits = (cfg['prlimits'] || []).map { |v| PrLimit.load(v) }
    end
  end
end
