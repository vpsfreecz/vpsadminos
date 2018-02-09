require 'yaml'

module OsCtld
  class Container
    include Lockable
    include CGroup::Params
    include Assets::Definition
    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    def self.default_dataset(pool, id)
      name = File.join(pool.ct_ds, id)
      Zfs::Dataset.new(name, base: name)
    end

    attr_reader :pool, :id, :user, :dataset, :group, :distribution, :version,
      :hostname, :dns_resolvers, :nesting, :prlimits, :mounts, :migration_log
    attr_accessor :state, :init_pid

    # @param pool [Pool]
    # @param id [String]
    # @param user [User, nil]
    # @param group [Group, nil]
    # @param dataset [String, nil]
    # @param opts [Hash] options
    # @option opts [Boolean] load load config
    # @option opts [String] load_from load from this string instead of config file
    # @option opts [Boolean] staged create a staged container
    def initialize(pool, id, user = nil, group = nil, dataset = nil, opts = {})
      init_lock

      opts[:load] = true unless opts.has_key?(:load)

      @pool = pool
      @id = id
      @user = user
      @group = group
      @dataset = dataset
      @state = opts[:staged] ? :staged : :unknown
      @init_pid = nil
      @cgparams = []
      @prlimits = []
      @mounts = []
      @hostname = nil
      @dns_resolvers = nil
      @nesting = false

      load_config(opts[:load_from]) if opts[:load]
    end

    def ident
      "#{pool.name}:#{id}"
    end

    def configure(distribution, version)
      @distribution = distribution
      @version = version
      @netifs = []
      @nesting = false
      save_config
    end

    def assets
      define_assets do |add|
        # Datasets
        add.dataset(
          dataset,
          desc: "Container's rootfs",
          uidoffset: uid_offset,
          gidoffset: gid_offset
        )

        # Directories and files
        add.directory(
          lxc_dir,
          desc: 'LXC configuration',
          owner: 0,
          group: user.ugid,
          mode: 0750
        )
        add.file(
          lxc_config_path,
          desc: 'LXC base config',
          owner: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('network'),
          desc: 'LXC network config',
          owner: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('prlimits'),
          desc: 'LXC resource limits',
          owner: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('mounts'),
          desc: 'LXC mounts',
          owner: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          File.join(lxc_dir, '.bashrc'),
          desc: 'Shell configuration file for osctl ct su',
          owner: 0,
          group: 0,
          mode: 0644
        )

        add.file(
          config_path,
          desc: 'Container config for osctld',
          owner: 0,
          group: 0,
          mode: 0400
        )
        add.file(
          log_path,
          desc: 'LXC log file',
          owner: 0,
          group: user.ugid,
          mode: 0660
        )
      end
    end

    def chown(user)
      @user = user
      save_config
      configure_lxc
      configure_bashrc
    end

    def chgrp(grp)
      @group = grp
      save_config
      configure_lxc
      configure_bashrc
    end

    def state=(v)
      if state == :staged
        case v
        when :complete
          @state = :stopped
          save_config

        when :running
          @state = v
          save_config
        end

        return
      end

      @state = v
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

    def can_start?
      state != :staged
    end

    def dir
      dataset.mountpoint
    end

    def lxc_home(user: nil, group: nil)
      (group || self.group).userdir(user || self.user)
    end

    def lxc_dir(user: nil, group: nil)
      File.join(lxc_home(user: user, group: group), id)
    end

    def rootfs
      File.join(dir, 'private')
    end

    def runtime_rootfs
      fail 'container is not running' unless running?
      fail 'init_pid not set' unless init_pid

      File.join('/proc', init_pid.to_s, 'root')
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

    def netifs
      @netifs.clone
    end

    def netif_by(name)
      @netifs.detect { |netif| netif.name == name }
    end

    def add_netif(netif)
      @netifs << netif
      save_config

      Eventd.report(
        :ct_netif,
        action: :add,
        pool: pool.name,
        id: id,
        name: netif.name,
      )
    end

    def del_netif(netif)
      @netifs.delete(netif)
      save_config

      Eventd.report(
        :ct_netif,
        action: :remove,
        pool: pool.name,
        id: id,
        name: netif.name,
      )
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
        when :hostname
          original = @hostname
          @hostname = v
          DistConfig.run(self, :set_hostname, original: original)

        when :dns_resolvers
          @dns_resolvers = v
          DistConfig.run(self, :dns_resolvers)

        when :nesting
          @nesting = v

        when :distribution
          @distribution = v[:name]
          @version = v[:version]
        end
      end

      save_config
      configure_base
    end

    def unset(opts)
      opts.each do |k, v|
        case k
        when :hostname
          @hostname = nil

        when :dns_resolvers
          @dns_resolvers = nil
        end
      end

      save_config
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

    def mount_add(mnt)
      exclusively do
        mounts << mnt
      end

      save_config
      configure_mounts
    end

    def mount_remove(mountpoint)
      exclusively do
        mnt = mounts.detect { |m| m.mountpoint == mountpoint }
        next unless mnt

        mounts.delete(mnt)
      end

      save_config
      configure_mounts
    end

    def configure_lxc
      configure_base
      configure_prlimits
      configure_network
      configure_mounts
    end

    def configure_base
      Template.render_to('ct/config', {
        distribution: distribution,
        ct: self,
        hook_start_host: OsCtld::hook_run('ct-start', pool),
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

    def configure_mounts
      Template.render_to('ct/mounts', {
        mounts: mounts,
      }, lxc_config_path('mounts'))
    end

    def configure_bashrc
      Template.render_to('ct/bashrc', {
        ct: self,
        override: %w(
          attach cgroup console device execute info ls monitor stop top wait
        ),
        disable: %w(
          autostart checkpoint clone copy create destroy freeze snapshot
          start-ephemeral unfreeze unshare
        ),
      }, File.join(lxc_dir, '.bashrc'))
    end

    def open_migration_log(role, opts = {})
      @migration_log = Migration::Log.new(role: role, opts: opts)
      save_config
    end

    def close_migration_log(save: true)
      @migration_log = nil
      save_config if save
    end

    def save_config
      data = {
        'user' => user.name,
        'group' => group.name,
        'dataset' => dataset.name,
        'distribution' => distribution,
        'version' => version,
        'net_interfaces' => @netifs.map { |v| v.save },
        'cgparams' => dump_cgparams(cgparams),
        'prlimits' => prlimits.map(&:dump),
        'mounts' => mounts.map(&:dump),
        'hostname' => hostname,
        'dns_resolvers' => dns_resolvers,
        'nesting' => nesting,
      }

      data['state'] = 'staged' if state == :staged
      data['migration_log'] = migration_log.dump if migration_log

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(data))
      end

      File.chown(0, 0, config_path)
    end

    def log_path
      File.join(pool.log_path, 'ct', "#{id}.log")
    end

    def log_type
      "ct=#{pool.name}:#{id}"
    end

    protected
    def load_config(config = nil)
      if config
        cfg = YAML.load(config)
      else
        cfg = YAML.load_file(config_path)
      end

      @state = cfg['state'].to_sym if cfg['state']
      @user ||= DB::Users.find(cfg['user']) || (raise "user not found")
      @group ||= DB::Groups.find(cfg['group']) || (raise "group not found")

      unless @dataset
        if cfg['dataset']
          @dataset = Zfs::Dataset.new(cfg['dataset'], base: cfg['dataset'])
        else
          @dataset = Container.default_dataset(pool, id)
        end
      end

      @distribution = cfg['distribution']
      @version = cfg['version']
      @hostname = cfg['hostname']
      @dns_resolvers = cfg['dns_resolvers']
      @nesting = cfg['nesting'] || false
      @migration_log = Migration::Log.load(cfg['migration_log']) if cfg['migration_log']

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
      @mounts = (cfg['mounts'] || []).map { |v| Mount.load(self, v) }
    end
  end
end
