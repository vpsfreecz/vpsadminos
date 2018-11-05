require 'libosctl'
require 'yaml'
require 'osctld/lockable'
require 'osctld/manipulable'
require 'osctld/assets/definition'

module OsCtld
  class Container
    include Lockable
    include Manipulable
    include Assets::Definition
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def self.default_dataset(pool, id)
      name = File.join(pool.ct_ds, id)
      OsCtl::Lib::Zfs::Dataset.new(name, base: name)
    end

    attr_reader :pool, :id, :user, :dataset, :group, :distribution, :version,
      :arch, :autostart, :hostname, :dns_resolvers, :nesting, :prlimits, :mounts,
      :migration_log, :cgparams, :devices, :seccomp_profile, :apparmor, :attrs,
      :state, :init_pid

    # @param pool [Pool]
    # @param id [String]
    # @param user [User, nil]
    # @param group [Group, nil]
    # @param dataset [String, nil]
    # @param opts [Hash] options
    # @option opts [Boolean] load load config
    # @option opts [String] load_from load from this string instead of config file
    # @option opts [Boolean] staged create a staged container
    # @option opts [Boolean] devices determines whether devices are initialized
    def initialize(pool, id, user = nil, group = nil, dataset = nil, opts = {})
      init_lock
      init_manipulable

      opts[:load] = true unless opts.has_key?(:load)

      @pool = pool
      @id = id
      @user = user
      @group = group
      @dataset = dataset
      @state = opts[:staged] ? :staged : :unknown
      @init_pid = nil
      @netifs = []
      @cgparams = nil
      @devices = nil
      @prlimits = []
      @mounts = nil
      @hostname = nil
      @dns_resolvers = nil
      @nesting = false
      @seccomp_profile = nil
      @apparmor = AppArmor.new(self)
      @attrs = Attributes.new
      @dist_network_configured = false

      if opts[:load]
       load_config(opts[:load_from], !opts.has_key?(:devices) || opts[:devices])
      end
    end

    def ident
      "#{pool.name}:#{id}"
    end

    def configure(distribution, version, arch)
      exclusively do
        @distribution = distribution
        @version = version
        @arch = arch
        @netifs = []
        @nesting = false
        @seccomp_profile = default_seccomp_profile
        @cgparams = CGroup::ContainerParams.new(self)
        @devices = Devices::ContainerManager.new(self)
        @mounts = Mount::Manager.new(self)
        devices.init
        save_config
      end
    end

    def assets
      define_assets do |add|
        # Datasets
        add.dataset(
          dataset,
          desc: "Container's rootfs dataset",
          uidmap: uid_map.map(&:to_a),
          gidmap: gid_map.map(&:to_a),
          user: root_host_uid,
          group: root_host_gid,
          mode: 0770
        )

        # Directories and files
        add.directory(
          rootfs,
          desc: "Container's rootfs",
          user: root_host_uid,
          group: root_host_gid,
          mode: 0755
        )

        add.directory(
          user_hook_script_dir,
          desc: 'User supplied script hooks',
          user: 0,
          group: 0,
          mode: 0700
        )
        add.directory(
          lxc_dir,
          desc: 'LXC configuration',
          user: 0,
          group: user.ugid,
          mode: 0750
        )
        add.file(
          lxc_config_path,
          desc: 'LXC base config',
          user: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('network'),
          desc: 'LXC network config',
          user: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('cgparams'),
          desc: 'LXC cgroup parameters',
          user: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('prlimits'),
          desc: 'LXC resource limits',
          user: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          lxc_config_path('mounts'),
          desc: 'LXC mounts',
          user: 0,
          group: 0,
          mode: 0644
        )
        add.file(
          File.join(lxc_dir, '.bashrc'),
          desc: 'Shell configuration file for osctl ct su',
          user: 0,
          group: 0,
          mode: 0644
        )

        add.file(
          config_path,
          desc: 'Container config for osctld',
          user: 0,
          group: 0,
          mode: 0400
        )
        add.file(
          log_path,
          desc: 'LXC log file',
          user: 0,
          group: user.ugid,
          mode: 0660
        )
      end
    end

    # Duplicate the container with a different ID
    #
    # The returned container has `state` set to `:staged` and its assets will
    # not exist, so the caller has to build the container and call
    # `ct.state = :complete` for the container to become usable.
    #
    # @param id [String] new container id
    # @param opts [Hash] options
    # @option opts [Pool] :pool target pool, optional
    # @option opts [User] :user target user, optional
    # @option opts [Group] :group target group, optional
    # @option opts [String] :dataset target dataset, optional
    def dup(id, opts = {})
      ct = clone
      ct.send(:clone_from, self, id, opts)
      ct
    end

    # Mount the container's dataset
    # @param force [Boolean] ensure the datasets are mounted even if osctld
    #                        already mounted them
    def mount(force: false)
      return if !force && @mounted
      dataset.mount(recursive: true)
      @mounted = true
    end

    def chown(user)
      exclusively { @user = user }
      save_config
      configure_lxc
      configure_bashrc
    end

    def chgrp(grp, missing_devices: nil)
      exclusively { @group = grp }

      case missing_devices
      when 'provide'
        devices.ensure_all
        devices.create

      when 'remove'
        devices.remove_missing
        devices.create

      when 'check'
        devices.check_all_available!(grp)

      else
        fail "unsupported action for missing devices: '#{missing_devices}'"
      end

      save_config
      configure_lxc
      configure_bashrc
    end

    def state=(v)
      exclusively do
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
    end

    def init_pid=(v)
      exclusively { @init_pid = v }
    end

    def current_state
      s = inclusively { state }
      return s if s != :unknown

      ret = ct_control(self, :ct_status, ids: [id])

      if ret[:status]
        self.state = ret[:output][id.to_sym][:state].to_sym

      else
        self.state = :error
      end
    end

    def running?
      inclusively { state == :running }
    end

    def can_start?
      inclusively { state != :staged && state != :error && pool.active? }
    end

    def starting
      @dist_network_configured = false
    end

    def stopped
      @dist_network_configured = false
    end

    def can_dist_configure_network?
      inclusively do
        next false if netifs.detect { |netif| !netif.can_run_distconfig? }
        true
      end
    end

    def dist_configure_network?
      !@dist_network_configured && can_dist_configure_network?
    end

    def dist_configure_network
      return unless dist_configure_network?

      DistConfig.run(self, :network)
      @dist_network_configured = true
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

    def devices_dir
      File.join(pool.devices_dir, id)
    end

    def user_hook_script_dir
      File.join(pool.user_hook_script_dir, 'ct', id)
    end

    def uid_map
      user.uid_map
    end

    def gid_map
      user.gid_map
    end

    def root_host_uid
      @user.uid_map.ns_to_host(0)
    end

    def root_host_gid
      @user.gid_map.ns_to_host(0)
    end

    # Return a list of all container datasets
    # @return [Array<OsCtl::Lib::Zfs::Dataset>]
    def datasets
      [dataset] + dataset.descendants
    end

    # Iterate over all container datasets
    # @yieldparam ds [OsCtl::Lib::Zfs::Dataset]
    def each_dataset(&block)
      datasets.each(&block)
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

    def base_cgroup_path
      File.join(group.full_cgroup_path(user), "ct.#{id}")
    end

    def cgroup_path
      File.join(base_cgroup_path, 'user-owned')
    end

    def abs_cgroup_path(subsystem)
      File.join(CGroup::FS, CGroup.real_subsystem(subsystem), cgroup_path)
    end

    def abs_apply_cgroup_path(subsystem)
      File.join(CGroup::FS, CGroup.real_subsystem(subsystem), base_cgroup_path)
    end

    def set(opts)
      opts.each do |k, v|
        case k
        when :autostart
          @autostart = AutoStart::Config.new(self, v[:priority], v[:delay])

        when :hostname
          original = @hostname
          @hostname = OsCtl::Lib::Hostname.new(v)
          DistConfig.run(self, :set_hostname, original: original)

        when :dns_resolvers
          @dns_resolvers = v
          DistConfig.run(self, :dns_resolvers)

        when :nesting
          @nesting = true

        when :distribution
          @distribution = v[:name]
          @version = v[:version]
          @arch = v[:arch] if v[:arch]

        when :seccomp_profile
          @seccomp_profile = v

        when :attrs
          attrs.update(v)
        end
      end

      save_config
      configure_base
    end

    def unset(opts)
      opts.each do |k, v|
        case k
        when :autostart
          @autostart = false

        when :hostname
          @hostname = nil

        when :dns_resolvers
          @dns_resolvers = nil

        when :nesting
          @nesting = false

        when :seccomp_profile
          @seccomp_profile = default_seccomp_profile

        when :attrs
          v.each { |attr| attrs.unset(attr) }
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
      configure_cgparams
      configure_prlimits
      configure_network
      configure_mounts
    end

    def configure_base
      ErbTemplate.render_to('ct/config', {
        distribution: distribution,
        version: version,
        ct: self,
      }, lxc_config_path)
    end

    def configure_cgparams
      ErbTemplate.render_to('ct/cgparams', {
        cgparams: cgparams,
      }, lxc_config_path('cgparams'))
    end

    def configure_prlimits
      ErbTemplate.render_to('ct/prlimits', {
        prlimits: prlimits,
      }, lxc_config_path('prlimits'))
    end

    # Generate LXC network configuration
    def configure_network
      ErbTemplate.render_to('ct/network', {
        netifs: @netifs,
      }, lxc_config_path('network'))
    end

    def configure_mounts
      ErbTemplate.render_to('ct/mounts', {
        mounts: mounts.all_entries,
      }, lxc_config_path('mounts'))
    end

    def configure_bashrc
      ErbTemplate.render_to('ct/bashrc', {
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
        'arch' => arch,
        'net_interfaces' => @netifs.map { |v| v.save },
        'cgparams' => cgparams.dump,
        'devices' => devices.dump,
        'prlimits' => prlimits.map(&:dump),
        'mounts' => mounts.dump,
        'autostart' => autostart && autostart.dump,
        'hostname' => hostname && hostname.to_s,
        'dns_resolvers' => dns_resolvers,
        'nesting' => nesting,
        'seccomp_profile' => seccomp_profile == default_seccomp_profile \
                             ? nil : seccomp_profile,
        'attrs' => attrs.dump,
      }

      data['state'] = 'staged' if state == :staged
      data['migration_log'] = migration_log.dump if migration_log

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(data))
      end

      File.chown(0, 0, config_path)
    end

    def reload_config
      load_config
    end

    # @param config [String]
    def replace_config(config)
      load_config(config)
      save_config
    end

    def log_path
      File.join(pool.log_path, 'ct', "#{id}.log")
    end

    def log_type
      "ct=#{pool.name}:#{id}"
    end

    def manipulation_resource
      ['container', ident]
    end

    protected
    def load_config(config = nil, init_devices = true)
      if config
        cfg = YAML.load(config)
      else
        cfg = YAML.load_file(config_path)
      end

      @state = cfg['state'].to_sym if cfg['state']
      @user ||= DB::Users.find(cfg['user'], pool) || (raise "user not found")
      @group ||= DB::Groups.find(cfg['group'], pool) || (raise "group not found")

      unless @dataset
        if cfg['dataset']
          @dataset = OsCtl::Lib::Zfs::Dataset.new(cfg['dataset'], base: cfg['dataset'])
        else
          @dataset = Container.default_dataset(pool, id)
        end
      end

      @distribution = cfg['distribution']
      @version = cfg['version']
      @arch = cfg['arch']
      @autostart = cfg['autostart'] && AutoStart::Config.load(self, cfg['autostart'])
      @hostname = cfg['hostname'] && OsCtl::Lib::Hostname.new(cfg['hostname'])
      @dns_resolvers = cfg['dns_resolvers']
      @nesting = cfg['nesting'] || false
      @seccomp_profile = cfg['seccomp_profile'] || default_seccomp_profile
      @migration_log = Migration::Log.load(cfg['migration_log']) if cfg['migration_log']
      @cgparams = CGroup::ContainerParams.load(self, cfg['cgparams'])
      @prlimits = (cfg['prlimits'] || []).map { |v| PrLimit.load(v) }
      @attrs = Attributes.load(cfg['attrs'] || {})

      # It's necessary to load devices _before_ netifs. The device manager needs
      # to create cgroups first, in order for echo a > devices.deny to work.
      # If the container has a veth interface, the setup code switches to the
      # container's user, which creates cgroups in all subsystems. Devices then
      # can't be initialized properly.
      @devices = Devices::ContainerManager.load(self, cfg['devices'] || [])
      @devices.init if init_devices

      i = 0
      @netifs = (cfg['net_interfaces'] || []).map do |v|
        netif = NetInterface.for(v['type'].to_sym).new(self, i)
        netif.load(v)
        netif.setup
        i += 1
        netif
      end

      @mounts = Mount::Manager.load(self, cfg['mounts'] || [])
    end

    # Change the container so that it becomes a clone of `ct` with a different id
    # @param ct [Container] the source container
    # @param id [String] new container id
    # @param opts [Hash] options
    # @option opts [Pool] :pool target pool, optional
    # @option opts [User] :user target user, optional
    # @option opts [Group] :group target group, optional
    # @option opts [String] :dataset target dataset, optional
    def clone_from(ct, id, opts = {})
      @id = id
      @pool = opts[:pool] if opts[:pool]
      @user = opts[:user] if opts[:user]
      @group = opts[:group] if opts[:group]
      @init_pid = nil
      @state = :staged
      @migration_log = nil

      if opts[:dataset]
        @dataset = OsCtl::Lib::Zfs::Dataset.new(
          opts[:dataset],
          base: opts[:dataset],
        )
      else
        @dataset = Container.default_dataset(@pool, @id)
      end

      @apparmor = @apparmor.dup(self)
      @autostart = @autostart && @autostart.dup(self)
      @cgparams = cgparams.dup(self)
      @mounts = mounts.dup(self)

      @devices = devices.dup(self)
      devices.init

      @netifs = netifs.map { |netif| netif.dup(self) }
      netifs.each(&:setup)
    end

    def default_seccomp_profile
      File.join(Lxc::CONFIGS, 'common.seccomp')
    end
  end
end
