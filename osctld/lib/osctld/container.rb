require 'libosctl'
require 'osctld/lockable'
require 'osctld/manipulable'
require 'osctld/assets/definition'
require 'osctld/local_transfer/log'
require 'securerandom'

module OsCtld
  class Container
    include Lockable
    include Manipulable
    include Assets::Definition
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File
    include Utils::SwitchUser

    MAP_MODES = %w[native zfs].freeze
    StateObservation = Struct.new(:id, :state, :init_pid)

    DEFAULT_START_TIMEOUT = 120
    DEFAULT_STOP_TIMEOUT = 300

    def self.default_dataset(pool, id, dataset_cache: nil)
      name = File.join(pool.ct_ds, id)
      OsCtl::Lib::Zfs::Dataset.new(name, base: name, cache: dataset_cache)
    end

    attr_inclusive_reader :pool, :id, :user, :dataset, :group, :distribution, :version, :arch,
                          :vendor, :variant, :autostart, :ephemeral, :hostname, :dns_resolvers,
                          :nesting, :prlimits, :mounts, :send_log, :local_transfer_log, :netifs,
                          :cgparams, :cpu_package, :devices, :seccomp_profile, :apparmor, :attrs,
                          :state, :lxc_config,
                          :init_cmd, :start_menu, :impermanence, :raw_configs, :run_conf, :next_run_conf,
                          :hints, :map_mode, :incarnation_id

    alias ephemeral? ephemeral

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
    # @option opts [String] map_mode
    # @option opts [OsCtl::Lib::Zfs::DatasetCache] dataset_cache
    def initialize(pool, id, user = nil, group = nil, dataset = nil, opts = {})
      init_lock
      init_manipulable

      opts[:load] = true unless opts.has_key?(:load)

      if (user.nil? || group.nil?) && !opts[:load]
        raise ArgumentError, 'either set load: true or provide user and group'
      end

      @pool = pool
      @id = id
      @user = user
      @group = group
      @dataset = dataset
      @map_mode = opts[:map_mode]
      @state = opts[:staged] ? :staged : :unknown
      @local_transfer_log = nil
      @ephemeral = false
      @netifs = NetInterface::Manager.new(self)
      @cgparams = nil
      @devices = nil
      @prlimits = nil
      @mounts = nil
      @hostname = nil
      @dns_resolvers = nil
      @nesting = false
      @cpu_package = 'auto'
      @seccomp_profile = nil
      @apparmor = AppArmor.new(self)
      @lxc_config = Container::LxcConfig.new(self)
      @init_cmd = nil
      @raw_configs = Container::RawConfigs.new
      @attrs = Attributes.new
      @run_conf = nil
      @past_run_conf = nil
      @next_run_conf = nil
      @incarnation_id = SecureRandom.uuid
      @incarnation_id_persisted = false
      @lifecycle = nil
      @hints = Container::Hints.new(self)

      return unless opts[:load]

      load_opts = {
        init_devices: !opts.has_key?(:devices) || opts[:devices],
        dataset_cache: opts[:dataset_cache]
      }

      if opts[:load_from]
        load_config_string(opts[:load_from], **load_opts)
      else
        load_config_file(config_path, **load_opts)
      end
    end

    def ident
      inclusively { "#{pool.name}:#{id}" }
    end

    def configure(distribution, version, arch)
      exclusively do
        @distribution = distribution
        @version = version
        @arch = arch
        @netifs = NetInterface::Manager.new(self)
        @nesting = false
        @seccomp_profile = default_seccomp_profile
        @cgparams = CGroup::ContainerParams.new(self)
        @devices = Devices::Manager.new_for(self)
        @prlimits = PrLimits::Manager.default(self)
        @mounts = Mount::Manager.new(self)
        @run_conf ||= new_run_conf
        devices.init
        save_config
      end
    end

    def assets
      define_assets do |add|
        # Datasets
        add.dataset(
          dataset.to_s,
          desc: "Container's rootfs dataset",
          uidmap: map_mode == 'zfs' ? uid_map.map(&:to_a) : nil,
          gidmap: map_mode == 'zfs' ? gid_map.map(&:to_a) : nil,
          properties: if map_mode == 'native'
                        {
                          'uidmap' => 'none',
                          'gidmap' => 'none'
                        }
                      end,
          user: map_mode == 'zfs' ? root_host_uid : 0,
          group: map_mode == 'zfs' ? root_host_gid : 0,
          mode: 0o770,
          validate_if: mounted?
        )

        # Directories and files
        add.directory(
          rootfs,
          desc: "Container's rootfs",
          user: map_mode == 'zfs' ? root_host_uid : 0,
          group: map_mode == 'zfs' ? root_host_gid : 0,
          mode_bit_and: 0o111, # has all executable bits set
          validate_if: mounted?
        )

        add.directory(
          user_hook_script_dir,
          desc: 'User supplied script hooks',
          user: 0,
          group: 0,
          mode: 0o700
        )
        add.directory(
          lxc_dir,
          desc: 'LXC configuration',
          user: 0,
          group: user.ugid,
          mode: 0o750
        )

        lxc_config.assets(add)

        add.file(
          File.join(lxc_dir, '.bashrc'),
          desc: 'Shell configuration file for osctl ct su',
          user: 0,
          group: 0,
          mode: 0o644
        )

        add.file(
          config_path,
          desc: 'Container config for osctld',
          user: 0,
          group: 0,
          mode: 0o400
        )
        add.file(
          log_path,
          desc: 'LXC log file',
          user: 0,
          group: user.ugid,
          mode: 0o660
        )

        run_conf.assets(add) if run_conf

        devices.assets(add)
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

    # @return [Container::RunConfiguration]
    def new_run_conf(run_id: nil)
      if run_id
        Container::RunConfiguration.new(self, load_conf: false, run_id:)
      else
        Container::RunConfiguration.new(self, load_conf: false)
      end
    end

    # @return [Container::RunConfiguration]
    def get_run_conf
      run_conf || new_run_conf
    end

    # @return [Container::RunConfiguration, nil]
    def get_past_run_conf
      inclusively { @past_run_conf }
    end

    def forget_past_run_conf(run_conf = nil)
      exclusively do
        next false if run_conf && !@past_run_conf.equal?(run_conf)

        @past_run_conf = nil
        true
      end
    end

    # @param next_run_conf [Container::RunConfiguration]
    def set_next_run_conf(next_run_conf)
      exclusively { @next_run_conf = next_run_conf }
    end

    # This must be called on container start
    def init_run_conf(run_id: nil)
      ret = exclusively do
        if @run_conf
          if !run_id || @run_conf.run_id != run_id
            raise ConfigError,
                  "active run configuration #{@run_conf.run_id} does not match #{run_id}"
          end
        elsif @next_run_conf
          if run_id && @next_run_conf.run_id != run_id
            raise ConfigError,
                  "planned run configuration #{@next_run_conf.run_id} does not match #{run_id}"
          end

          @run_conf = @next_run_conf
          @next_run_conf = nil
        else
          @run_conf = new_run_conf(run_id:)
        end

        @run_conf.save
        @run_conf
      end

      # Generate LXC configs for current time namespace offsets
      reconfigure
      ret
    end

    def lifecycle
      lifecycle = @lifecycle
      return lifecycle if lifecycle

      exclusively do
        unless @lifecycle
          require 'osctld/container/lifecycle'
          @lifecycle = Container::Lifecycle.new(self)
        end

        @lifecycle
      end
    end

    def load_lifecycle_run_conf(run_id)
      run_conf = Container::RunConfiguration.load_generation(self, run_id)
      return unless run_conf

      exclusively do
        @run_conf = run_conf if @run_conf.nil? || @run_conf.run_id != run_id
      end
      run_conf
    end

    def ensure_incarnation_id_persisted
      return if inclusively { @incarnation_id_persisted }

      save_config
      exclusively { @incarnation_id_persisted = true }
    end

    # Call {#init_run_conf} unless {#run_conf} is already set
    # @return [Container::RunConfiguration]
    def ensure_run_conf
      exclusively do
        init_run_conf if @run_conf.nil?
        run_conf
      end
    end

    # Mount the container's dataset
    # @param force [Boolean] ensure the datasets are mounted even if osctld
    #                        already mounted them
    def mount(force: false)
      return if !force && mounted

      dataset.mount(recursive: true)
      self.mounted = true
    end

    # Unmount the container's dataset
    def unmount(force: false)
      return if !force && !mounted

      dataset.unmount(recursive: true)
      self.mounted = false
    end

    # Check if the container's dataset is mounted
    # @param force [Boolean] check if the dataset is mounted even if osctld
    #                        already mounted it
    def mounted?(force: false)
      if force || mounted.nil?
        self.mounted = dataset.mounted?(recursive: true)
      else
        mounted
      end
    end

    def map_mode=(new_mode)
      @map_mode = new_mode
      save_config
      lxc_config.configure
    end

    def chown(user)
      self.user = user
      save_config
      lxc_config.configure
      configure_bashrc
    end

    def chgrp(grp, missing_devices: nil)
      self.group = grp

      case missing_devices
      when 'provide'
        devices.ensure_all
        devices.init

      when 'remove'
        devices.remove_missing
        devices.init

      when 'check'
        devices.check_all_available!(group: grp)

      else
        raise "unsupported action for missing devices: '#{missing_devices}'"
      end

      save_config
      lxc_config.configure
      configure_bashrc
    end

    def state=(v)
      if state == :staged
        case v
        when :complete
          exclusively { @state = :stopped }
          save_config

        when :running
          exclusively { @state = v }
          save_config
        end

        return
      end

      exclusively { @state = v }
    end

    # Apply an LXC state observation only to the exact active run. The state,
    # init PID and aborted marker change under the same container lock, so a
    # late monitor event cannot mutate a replacement generation.
    def observe_run_state(run_id, value, init_pid: nil)
      exclusively do
        return false if @state == :error
        return false unless @run_conf
        return false unless @run_conf.run_id == run_id

        @state = value
        @run_conf.init_pid = init_pid if value.to_sym == :running && init_pid
        @run_conf.mark_aborted if %i[aborting aborted].include?(value.to_sym)
        true
      end
    end

    # Fetch current container state and init PID by forking into it
    # @return [#state, #init_pid]
    def current_state_observation
      observation = ContainerControl::Commands::State.run!(self)
      self.state = observation.state
      observation
    rescue ContainerControl::Error
      self.state = :error
      StateObservation.new(id, :error, nil)
    end

    # Fetch current container state by forking into it
    # @return [Symbol]
    def current_state
      current_state_observation.state
    end

    # Fetch current state and init PID if state is not known, otherwise return
    # the known observation.
    # @return [#state, #init_pid]
    def fresh_state_observation
      if state == :unknown
        current_state_observation
      else
        StateObservation.new(
          id,
          state,
          init_pid
        )
      end
    end

    # Fetch current state if the state is not known, otherwise return the known state
    # @return [Symbol]
    def fresh_state
      fresh_state_observation.state
    end

    def running?
      state == :running
    end

    def can_start?
      inclusively { state != :staged && state != :error && pool.active? }
    end

    def init_pid
      inclusively do
        @run_conf ? run_conf.init_pid : nil
      end
    end

    def starting(run_id)
      exclusively do
        return false unless run_conf
        return false unless run_conf.run_id == run_id

        true
      end
    end

    def stopped(run_id = nil)
      exclusively do
        if run_id
          return false unless run_conf
          return false if run_conf.run_id != run_id
        end

        if run_conf
          @past_run_conf = @run_conf
          @run_conf = nil
        end

        @state = :stopped
        true
      end
    end

    def abort_run_conf(run_conf)
      removed = exclusively do
        next false unless @run_conf.equal?(run_conf)

        @run_conf = nil
        true
      end

      run_conf.destroy if removed
      removed
    end

    def detach_run_conf(run_conf)
      removed = exclusively do
        if @run_conf.equal?(run_conf)
          @run_conf = nil
          true
        elsif @past_run_conf.equal?(run_conf)
          @past_run_conf = nil
          true
        else
          false
        end
      end

      run_conf.detach if removed
      removed
    end

    def can_dist_configure_network?
      inclusively do
        next false if netifs.detect { |netif| !netif.can_run_distconfig? }

        true
      end
    end

    def dir
      dataset.mountpoint
    end

    def lxc_home(user: nil, group: nil)
      inclusively { (group || self.group).userdir(user || self.user) }
    end

    def lxc_dir(user: nil, group: nil)
      inclusively { File.join(lxc_home(user:, group:), id) }
    end

    def rootfs
      File.join(dir, 'private')
    rescue SystemCommandFailed
      # Dataset for staged containers does not have to exist yet, relevant
      # primarily for ct show/list
      nil
    end

    def config_path
      inclusively { File.join(pool.conf_path, 'ct', "#{id}.yml") }
    end

    def user_hook_script_dir
      inclusively { File.join(pool.root_user_hook_script_dir, 'ct', id) }
    end

    def uid_map
      user.uid_map
    end

    def gid_map
      user.gid_map
    end

    def root_host_uid
      user.uid_map.ns_to_host(0)
    end

    def root_host_gid
      user.gid_map.ns_to_host(0)
    end

    # Return a list of all container datasets
    # @return [Array<OsCtl::Lib::Zfs::Dataset>]
    def datasets
      ds = inclusively { dataset }
      [ds] + ds.descendants
    end

    # Iterate over all container datasets
    # @yieldparam ds [OsCtl::Lib::Zfs::Dataset]
    def each_dataset(&)
      datasets.each(&)
    end

    def base_cgroup_path
      inclusively { File.join(group.full_cgroup_path(user), "ct.#{id}") }
    end

    def legacy_cgroup_path
      File.join(base_cgroup_path, 'user-owned')
    end

    def legacy_wrapper_cgroup_path
      File.join(base_cgroup_path, 'wrapper')
    end

    def run_cgroup_path(run_id)
      File.join(base_cgroup_path, 'runs', run_id.key)
    end

    def cgroup_path
      lifecycle_resource('user_cgroup', legacy_cgroup_path)
    end

    def wrapper_cgroup_path
      lifecycle_resource('wrapper_cgroup', legacy_wrapper_cgroup_path)
    end

    def entry_cgroup_path
      lifecycle_resource('lxc_monitor', File.join(legacy_cgroup_path, "lxc.monitor.#{id}"))
    end

    def lxc_payload_cgroup_path
      lifecycle_resource('lxc_payload', File.join(legacy_cgroup_path, "lxc.payload.#{id}"))
    end

    def lxc_inner_cgroup_path
      lifecycle_resource(
        'lxc_inner',
        File.join(legacy_cgroup_path, "lxc.payload.#{id}", 'inner')
      )
    end

    def lxc_pivot_cgroup_path
      lifecycle_resource('lxc_pivot', File.join(legacy_cgroup_path, "lxc.pivot.#{id}"))
    end

    def abs_cgroup_path(subsystem)
      CGroup.abs_cgroup_path(subsystem, cgroup_path)
    end

    def abs_apply_cgroup_path(subsystem)
      CGroup.abs_cgroup_path(subsystem, base_cgroup_path)
    end

    def active_cgroup_root
      lifecycle_resource('cgroup_root', base_cgroup_path)
    end

    # @return [Integer, nil] memory limit in bytes
    def find_memory_limit(parents: true)
      limit = cgparams.find_memory_limit

      if limit
        return limit
      elsif !parents
        return
      end

      group.find_memory_limit(parents:)
    end

    # @return [Integer, nil] swap limit in bytes
    def find_swap_limit(parents: true)
      limit = cgparams.find_swap_limit

      if limit
        return limit
      elsif !parents
        return
      end

      group.find_swap_limit(parents:)
    end

    # @return [Integer, nil] CPU limit in percent (100 % for one CPU)
    def find_cpu_limit(parents: true)
      limit = cgparams.find_cpu_limit

      if limit
        return limit
      elsif !parents
        return
      end

      group.find_cpu_limit(parents:)
    end

    def set(opts)
      opts.each do |k, v|
        case k
        when :autostart
          self.autostart = AutoStart::Config.new(self, v[:priority], v[:delay])

        when :ephemeral
          self.ephemeral = true

        when :hostname
          original = nil

          exclusively do
            original = @hostname
            @hostname = OsCtl::Lib::Hostname.new(v)
          end

          DistConfig.run(get_run_conf, :set_hostname, original:)

        when :dns_resolvers
          self.dns_resolvers = v
          DistConfig.run(get_run_conf, :dns_resolvers)

        when :nesting
          self.nesting = true

        when :distribution
          exclusively do
            @distribution = v[:name]
            @version = v[:version]
            @arch = v[:arch] if v[:arch]
            @vendor = v[:vendor]
            @variant = v[:variant]
          end

          if (rc = run_conf)
            rc.set_distribution(
              distribution:,
              version:,
              arch:,
              vendor:,
              variant:
            )
          end

        when :cpu_package
          self.cpu_package = v

        when :seccomp_profile
          self.seccomp_profile = v

        when :init_cmd
          self.init_cmd = v

        when :start_menu
          self.start_menu = Container::StartMenu.new(self, v[:timeout])

        when :impermanence
          self.impermanence = Container::Impermanence.new(v[:zfs_properties].transform_keys(&:to_s))

        when :raw_lxc
          raw_configs.lxc = v

        when :attrs
          attrs.update(v)
        end
      end

      save_config
      lxc_config.configure_base
    end

    def unset(opts)
      opts.each do |k, v|
        case k
        when :autostart
          self.autostart = false
          pool.autostart_plan.stop_ct(self)

        when :ephemeral
          self.ephemeral = false

        when :hostname
          self.hostname = nil
          DistConfig.run(get_run_conf, :unset_etc_hosts)

        when :dns_resolvers
          self.dns_resolvers = nil

        when :nesting
          self.nesting = false

        when :cpu_package
          self.cpu_package = 'auto'

        when :seccomp_profile
          self.seccomp_profile = default_seccomp_profile

        when :init_cmd
          self.init_cmd = nil

        when :start_menu
          clear_start_menu
          self.start_menu = nil

        when :impermanence
          self.impermanence = nil

        when :raw_lxc
          raw_configs.lxc = nil

        when :attrs
          v.each { |attr| attrs.unset(attr) }
        end
      end

      save_config
      lxc_config.configure_base
    end

    def setup_start_menu
      menu = start_menu
      menu.deploy if menu
    end

    def clear_start_menu
      menu = start_menu
      menu.unlink if menu
    end

    # Read hostname from a running container
    # @return [String, nil]
    def read_hostname
      return nil unless running?

      begin
        ContainerControl::Commands::GetHostname.run!(self)
      rescue ContainerControl::Error => e
        log(:warn, "Unable to read container hostname: #{e.message}")
        nil
      end
    end

    def update_hints
      hints.account_cpu_use
      save_config
    end

    # Regenerate LXC config
    def reconfigure
      lxc_config.configure
    end

    def configure_bashrc
      ErbTemplate.render_to('ct/bashrc', {
        ct: self,
        override: %w[
          attach cgroup console device execute freeze info ls monitor stop top
          unfreeze wait
        ],
        disable: %w[
          autostart checkpoint clone copy create destroy snapshot
          start-ephemeral unshare
        ]
      }, File.join(lxc_dir, '.bashrc'))
    end

    def open_send_log(role, token, opts = {})
      exclusively do
        self.send_log = SendReceive::Log.new(role:, token:, opts:)
        save_config
      end
    end

    def close_send_log(save: true)
      exclusively do
        send_log.close
        self.send_log = nil
        save_config if save
      end
    end

    def open_local_transfer_log(role, opts = {})
      exclusively do
        self.local_transfer_log = LocalTransfer::Log.new(role:, opts:)
        save_config
      end
    end

    def close_local_transfer_log(save: true)
      exclusively do
        local_transfer_log.close
        self.local_transfer_log = nil
        save_config if save
      end
    end

    def transfer_log
      inclusively { send_log || local_transfer_log }
    end

    def transfer_in_progress?
      inclusively { !!send_log || !!local_transfer_log }
    end

    # Unregister the container from internal uses in osctld, e.g. on pool export
    def unregister
      exclusively do
        SendReceive::Tokens.free(send_log.token) if send_log
      end
    end

    # Export to clients
    def export
      lifecycle_record = lifecycle.snapshot
      lifecycle_run = lifecycle_record['active_run_id'] &&
                      lifecycle_record.fetch('runs')[lifecycle_record['active_run_id']]
      residual_runs = lifecycle_record.fetch('runs').values.select do |run|
        run['role'] == 'residual'
      end
      lifecycle_policy = lifecycle_record['policy']
      policy_hazards =
        if lifecycle_policy&.fetch('tainted', false)
          [
            'container cgroup policy is tainted: ' \
            "#{lifecycle_policy['rollback_error'] || lifecycle_policy['error']}"
          ]
        else
          []
        end

      inclusively do
        {
          pool: pool.name,
          id:,
          user: user.name,
          group: group.name,
          uid_map: user.uid_map.map(&:to_h),
          gid_map: user.gid_map.map(&:to_h),
          map_mode: map_mode,
          dataset: dataset.name,
          rootfs:,
          boot_dataset: run_conf ? run_conf.dataset.name : dataset.name,
          boot_rootfs: run_conf ? run_conf.rootfs : rootfs,
          lxc_path: lxc_home,
          lxc_dir:,
          group_path: cgroup_path,
          distribution: run_conf ? run_conf.distribution : distribution,
          version: run_conf ? run_conf.version : version,
          arch: run_conf ? run_conf.arch : arch,
          vendor: run_conf ? run_conf.vendor : vendor,
          variant: run_conf ? run_conf.variant : variant,
          state:,
          init_pid:,
          lifecycle_desired_state: lifecycle_record.fetch('desired_state'),
          lifecycle_state: lifecycle_run&.fetch('phase'),
          lifecycle_run_id: lifecycle_record['active_run_id'],
          lifecycle_revision: lifecycle_record.fetch('revision'),
          lifecycle_residuals: residual_runs.length,
          lifecycle_residual_run_ids: residual_runs.map do |run|
            Container::RunId.load(run.fetch('id')).to_s
          end,
          lifecycle_hazards: (
            residual_runs.flat_map { |run| run.fetch('hazards', []) } +
            policy_hazards
          ).uniq,
          lifecycle_policy_tainted: lifecycle_policy&.fetch('tainted', false) || false,
          lifecycle_policy_error: lifecycle_policy&.fetch('error', nil),
          lifecycle_policy_rollback_error: lifecycle_policy&.fetch(
            'rollback_error',
            nil
          ),
          autostart: autostart ? true : false,
          autostart_priority: autostart && autostart.priority,
          autostart_delay: autostart && autostart.delay,
          ephemeral:,
          hostname:,
          dns_resolvers:,
          nesting:,
          seccomp_profile:,
          init_cmd: format_user_init_cmd,
          cpu_package_inuse: run_conf ? run_conf.cpu_package : nil,
          cpu_package_set: cpu_package,
          cpu_limit: find_cpu_limit(parents: false),
          memory_limit: find_memory_limit(parents: false),
          swap_limit: find_swap_limit(parents: false),
          start_menu: start_menu ? true : false,
          start_menu_timeout: start_menu && start_menu.timeout,
          impermanence: impermanence ? true : false,
          impermanence_zfs_properties: impermanence&.zfs_properties,
          raw_lxc: raw_configs.lxc,
          log_file: log_path
        }.merge!(attrs.export)
      end
    end

    # Dump to config
    def dump_config
      inclusively do
        data = {
          'user' => user.name,
          'group' => group.name,
          'incarnation_id' => incarnation_id,
          'dataset' => dataset.name,
          'map_mode' => map_mode,
          'distribution' => distribution,
          'version' => version,
          'arch' => arch,
          'vendor' => vendor,
          'variant' => variant,
          'net_interfaces' => netifs.dump,
          'cgparams' => cgparams.dump,
          'devices' => devices.dump,
          'prlimits' => prlimits.dump,
          'mounts' => mounts.dump,
          'autostart' => autostart && autostart.dump,
          'ephemeral' => ephemeral,
          'hostname' => hostname && hostname.to_s,
          'dns_resolvers' => dns_resolvers,
          'nesting' => nesting,
          'seccomp_profile' => if seccomp_profile == default_seccomp_profile
                                 nil
                               else
                                 seccomp_profile
                               end,
          'cpu_package' => cpu_package,
          'init_cmd' => init_cmd,
          'start_menu' => start_menu && start_menu.dump,
          'impermanence' => impermanence && impermanence.dump,
          'raw' => raw_configs.dump,
          'attrs' => attrs.dump,
          'hints' => hints.dump
        }

        data['state'] = 'staged' if state == :staged
        data['send_log'] = send_log.dump if send_log
        data['local_transfer_log'] = local_transfer_log.dump if local_transfer_log

        data
      end
    end

    def save_config
      data = dump_config

      regenerate_file(config_path, 0o400) do |f|
        f.write(OsCtl::Lib::ConfigFile.dump_yaml(data))
      end

      File.chown(0, 0, config_path)
      exclusively { @incarnation_id_persisted = true }
    end

    def reload_config
      incarnation_id_present =
        load_config_file(preserve_incarnation_id: true)
      save_config unless incarnation_id_present
    end

    # @param config [String]
    def replace_config(config)
      load_config_string(config, preserve_incarnation_id: true)
      save_config
    end

    # Update keys/values from `new_config` in the container's config
    # @param new_config [Hash]
    def patch_config(new_config)
      exclusively do
        tmp = dump_config
        tmp.update(new_config)
        load_config_hash(tmp, preserve_incarnation_id: true)
        save_config
      end
    end

    def format_user_init_cmd
      (init_cmd || default_init_cmd).join(' ')
    end

    def format_exec_init_cmd
      cmd = init_cmd || default_init_cmd
      menu = start_menu

      if menu
        menu.init_cmd(cmd)
      else
        cmd
      end.join(' ')
    end

    def syslogns_tag
      max_size = OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE

      tag =
        if id.bytesize >= max_size - 1 # -1 for colon used as a separator
          id[0..(max_size - 1)]
        else
          v = ident
          v = v[1..] while v.bytesize > max_size
          v
        end

      tag.rjust(max_size)
    end

    def log_path
      inclusively { File.join(pool.log_path, 'ct', "#{id}.log") }
    end

    def log_type
      inclusively { "ct=#{pool.name}:#{id}" }
    end

    def manipulation_resource
      ['container', ident]
    end

    protected

    attr_exclusive_writer :pool, :id, :user, :dataset, :group, :distribution, :version, :arch,
                          :vendor, :variant, :autostart, :ephemeral, :hostname, :dns_resolvers,
                          :nesting, :prlimits, :mounts, :send_log, :local_transfer_log, :netifs,
                          :cgparams, :cpu_package, :devices, :seccomp_profile, :apparmor, :attrs,
                          :lxc_config, :init_cmd, :start_menu, :impermanence
    attr_synchronized_accessor :mounted

    def load_config_file(path = nil, **)
      cfg = parse_yaml do
        OsCtl::Lib::ConfigFile.load_yaml_file(path || config_path)
      end

      load_config_hash(cfg, **)
    end

    def load_config_string(str, **)
      cfg = parse_yaml { OsCtl::Lib::ConfigFile.load_yaml(str) }
      load_config_hash(cfg, **)
    end

    def parse_yaml
      yield
    rescue Psych::Exception => e
      raise ConfigError.new("Unable to load config of container #{id}", e)
    end

    def load_config_hash(
      cfg,
      init_devices: true,
      dataset_cache: nil,
      preserve_incarnation_id: false
    )
      cfg = Container::Adaptor.adapt(self, cfg)
      incarnation_id_present = !cfg['incarnation_id'].nil?

      exclusively do
        if preserve_incarnation_id \
           && cfg['incarnation_id'] \
           && cfg['incarnation_id'] != @incarnation_id
          raise ConfigError,
                "container #{id}: incarnation_id cannot be changed"
        end

        @state = cfg['state'].to_sym if cfg['state']
        if cfg['incarnation_id']
          @incarnation_id = cfg['incarnation_id'] \
            unless preserve_incarnation_id
          @incarnation_id_persisted = true
        elsif preserve_incarnation_id
          @incarnation_id_persisted = false
        end
        @user ||= DB::Users.find(cfg['user'], pool) || (raise ConfigError, "container #{id}: user '#{cfg['user']}' not found")
        @group ||= DB::Groups.find(cfg['group'], pool) || (raise ConfigError, "container #{id}: group '#{cfg['group']}' not found")

        @dataset ||= if cfg['dataset']
                       OsCtl::Lib::Zfs::Dataset.new(
                         cfg['dataset'],
                         base: cfg['dataset'],
                         cache: dataset_cache
                       )
                     else
                       Container.default_dataset(
                         pool,
                         id,
                         dataset_cache:
                       )
                     end

        @map_mode ||= cfg.fetch('map_mode', 'zfs')
        @distribution = cfg['distribution']
        @version = cfg['version']
        @arch = cfg['arch']
        @vendor = cfg.fetch('vendor', 'default')
        @variant = cfg.fetch('variant', 'default')
        @autostart = cfg['autostart'] && AutoStart::Config.load(self, cfg['autostart'])
        @ephemeral = cfg['ephemeral']
        @hostname = cfg['hostname'] && OsCtl::Lib::Hostname.new(cfg['hostname'])
        @dns_resolvers = cfg['dns_resolvers']
        @nesting = cfg['nesting'] || false
        @cpu_package = cfg.fetch('cpu_package', 'auto')
        @seccomp_profile = cfg['seccomp_profile'] || default_seccomp_profile
        @init_cmd = cfg['init_cmd']

        @start_menu =
          if !cfg.has_key?('start_menu') || cfg['start_menu']
            Container::StartMenu.load(self, cfg['start_menu'] || {})
          end

        @impermanence =
          if cfg['impermanence']
            Container::Impermanence.load(cfg['impermanence'])
          end

        @run_conf = Container::RunConfiguration.load(self)
        @lifecycle = nil unless preserve_incarnation_id

        if cfg['send_log']
          @send_log = SendReceive::Log.load(cfg['send_log'])
          SendReceive::Tokens.register(@send_log.token)
        end

        if cfg['local_transfer_log']
          @local_transfer_log = LocalTransfer::Log.load(cfg['local_transfer_log'])
        end

        @cgparams = CGroup::ContainerParams.load(self, cfg['cgparams'])
        @prlimits = PrLimits::Manager.load(self, cfg['prlimits'] || {})
        @raw_configs = Container::RawConfigs.new(cfg['raw'] || {})
        @attrs = Attributes.load(cfg['attrs'] || {})

        # It's necessary to load devices _before_ netifs. The device manager needs
        # to create cgroups first, in order for echo a > devices.deny to work.
        # If the container has a veth interface, the setup code switches to the
        # container's user, which creates cgroups in all subsystems. Devices then
        # can't be initialized properly.
        @devices = Devices::Manager.load(self, cfg['devices'] || [])
        @devices.init if init_devices

        @netifs = NetInterface::Manager.load(self, cfg['net_interfaces'] || [])
        @mounts = Mount::Manager.load(self, cfg['mounts'] || [])

        @hints = Container::Hints.load(self, cfg['hints'] || {})
      end

      incarnation_id_present
    end

    # Change the container so that it becomes a clone of `ct` with a different id
    # @param ct [Container] the source container
    # @param id [String] new container id
    # @param opts [Hash] options
    # @option opts [Pool] :pool target pool, optional
    # @option opts [User] :user target user, optional
    # @option opts [Group] :group target group, optional
    # @option opts [String] :dataset target dataset, optional
    # @option opts [Boolean] :network_interfaces
    def clone_from(_ct, id, opts = {})
      init_lock
      init_manipulable

      @id = id
      @pool = opts[:pool] if opts[:pool]
      @user = opts[:user] if opts[:user]
      @group = opts[:group] if opts[:group]
      @state = :staged
      @incarnation_id = SecureRandom.uuid
      @incarnation_id_persisted = false
      @send_log = nil
      @local_transfer_log = nil

      @dataset = if opts[:dataset]
                   OsCtl::Lib::Zfs::Dataset.new(
                     opts[:dataset],
                     base: opts[:dataset]
                   )
                 else
                   Container.default_dataset(@pool, @id)
                 end

      @apparmor = @apparmor.dup(self)
      @autostart &&= @autostart.dup(self)
      @cgparams = cgparams.dup(self)
      @prlimits = prlimits.dup(self)
      @mounts = mounts.dup(self)
      @start_menu &&= @start_menu.dup(self)
      @impermanence &&= @impermanence.dup
      @lxc_config = lxc_config.dup(self)
      @raw_configs = raw_configs.dup
      @attrs = attrs.dup
      @run_conf = nil
      @next_run_conf = nil
      @past_run_conf = nil
      @lifecycle = nil

      @devices = devices.dup(self)
      devices.init

      if opts[:network_interfaces]
        @netifs = netifs.dup(self)
        netifs.each(&:setup)
      else
        @netifs = NetInterface::Manager.new(self)
      end

      @hints = hints.dup(self)
    end

    def default_seccomp_profile
      '/etc/lxc/config/common.seccomp'
    end

    def default_init_cmd
      ['/sbin/init']
    end

    def lifecycle_resource(name, fallback)
      lc = inclusively { @lifecycle }
      return fallback unless lc

      active = lc.active_run
      active ? active.fetch('resources').fetch(name, fallback) : fallback
    end
  end
end
