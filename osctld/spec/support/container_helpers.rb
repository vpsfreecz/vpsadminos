# frozen_string_literal: true

require 'fileutils'

module ContainerHelpers
  FakeSharedDir = Struct.new(:path, :mountpoint, keyword_init: true) do
    def dup(_new_ct = nil)
      self.class.new(path:, mountpoint:)
    end
  end

  FakeNetInterface = Struct.new(:can_run_distconfig, keyword_init: true) do
    def can_run_distconfig?
      can_run_distconfig != false
    end

    def save
      {
        'type' => 'fake',
        'can_run_distconfig' => can_run_distconfig?
      }
    end

    def dup(_new_ct)
      self.class.new(can_run_distconfig:)
    end
  end

  class FakeHostLinkNetInterface
    attr_reader :type, :name

    def initialize(type:, name:, identity:, tainted:, saved:)
      @type = type
      @name = name
      @identity = identity
      @tainted = tainted
      @saved = saved
    end

    def host_link_identity = @identity
    def host_link_tainted? = @tainted
    def save = @saved
  end

  class FakeRunConfigContainer
    attr_accessor :distribution, :version, :arch, :vendor, :variant
    attr_reader :pool, :id, :dataset, :user, :group, :uid_map, :gid_map, :map_mode,
                :lxc_dir, :log_path, :config_path, :log_type, :ident, :mount_calls

    def initialize(pool:, id:, dataset:, user:, group:, distribution:, version:, arch:,
                   vendor: 'default', variant: 'default', map_mode: 'zfs',
                   can_dist_configure_network: true)
      @pool = pool
      @id = id
      @dataset = dataset
      @user = user
      @group = group
      @uid_map = user.uid_map
      @gid_map = user.gid_map
      @map_mode = map_mode
      @distribution = distribution
      @version = version
      @arch = arch
      @vendor = vendor
      @variant = variant
      @lxc_dir = File.join(group.userdir(user), id)
      @log_path = File.join(pool.log_path, 'ct', "#{id}.log")
      @config_path = File.join(pool.conf_path, 'ct', "#{id}.yml")
      @log_type = "ct=#{pool.name}:#{id}"
      @ident = "#{pool.name}:#{id}"
      @can_dist_configure_network = can_dist_configure_network
      @mount_calls = []
    end

    def can_dist_configure_network?
      @can_dist_configure_network
    end

    def mount(force: false)
      @mount_calls << force
    end
  end

  def build_container_pool(root:, name: 'tank', dataset: name)
    pool = build_fake_pool(root:, name:, dataset:)

    FileUtils.mkdir_p(File.join(pool.conf_path, 'ct'))
    FileUtils.mkdir_p(File.join(pool.log_path, 'ct'))
    FileUtils.mkdir_p(File.join(root, 'hooks', 'ct'))
    FileUtils.mkdir_p(File.join(root, 'run', 'containers'))

    pool.define_singleton_method(:ct_ds) { File.join(dataset, 'ct') }
    pool.define_singleton_method(:ct_dir) { File.join(root, 'run', 'containers') }
    pool.define_singleton_method(:root_user_hook_script_dir) { File.join(root, 'hooks') }
    pool.define_singleton_method(:active?) { true }
    pool.define_singleton_method(:parallel_start) { 2 }
    pool.define_singleton_method(:parallel_stop) { 4 }

    autostart_plan = Object.new
    autostart_plan.define_singleton_method(:stop_ct) do |_ct|
      nil
    end
    pool.define_singleton_method(:autostart_plan) { autostart_plan }

    pool
  end

  def build_container_fixture(root:, id: 'ct1', pool: nil, user: nil, group: nil, dataset: nil,
                              load: false, load_from: nil, staged: false, devices: true,
                              map_mode: 'zfs', distribution: 'almalinux', version: '9',
                              arch: 'x86_64', vendor: 'default', variant: 'default')
    pool ||= build_container_pool(root:)
    user ||= FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
    group ||= FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
    dataset ||= FakeObjects::FakeDataset.new(
      name: File.join(pool.ct_ds, id),
      mountpoint: File.join(root, 'datasets', id),
      descendants: []
    )

    FileUtils.mkdir_p(user.userdir)
    FileUtils.mkdir_p(group.userdir(user))
    FileUtils.mkdir_p(dataset.mountpoint)

    ct = OsCtld::Container.new(
      pool,
      id,
      user,
      group,
      dataset,
      load:,
      load_from:,
      staged:,
      devices:,
      map_mode:
    )

    ct.instance_variable_set('@distribution', distribution)
    ct.instance_variable_set('@version', version)
    ct.instance_variable_set('@arch', arch)
    ct.instance_variable_set('@vendor', vendor)
    ct.instance_variable_set('@variant', variant)

    ct
  end

  def build_run_config_container(root:, id: 'ct1', pool: nil, user: nil, group: nil, dataset: nil,
                                 distribution: 'almalinux', version: '9', arch: 'x86_64',
                                 vendor: 'default', variant: 'default', map_mode: 'zfs',
                                 can_dist_configure_network: true)
    pool ||= build_container_pool(root:)
    user ||= FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
    group ||= FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
    dataset ||= FakeObjects::FakeDataset.new(
      name: File.join(pool.ct_ds, id),
      mountpoint: File.join(root, 'datasets', id)
    )

    FileUtils.mkdir_p(user.userdir)
    FileUtils.mkdir_p(group.userdir(user))
    FileUtils.mkdir_p(dataset.mountpoint)
    FileUtils.mkdir_p(File.join(group.userdir(user), id))

    FakeRunConfigContainer.new(
      pool:,
      id:,
      dataset:,
      user:,
      group:,
      distribution:,
      version:,
      arch:,
      vendor:,
      variant:,
      map_mode:,
      can_dist_configure_network:
    )
  end

  def build_fake_run_configuration_class(load_return: nil)
    Class.new do
      class << self
        attr_accessor :load_return

        def load(ct)
          return load_return.call(ct) if load_return.respond_to?(:call)

          load_return
        end
      end

      attr_reader :ct, :rootfs, :destroy_calls, :retirement_calls, :save_calls,
                  :distribution_updates, :lifecycle_lease_count,
                  :closed_lifecycle_lease_count, :destroy_observed_lease_count
      attr_accessor :dataset, :distribution, :version, :arch, :vendor, :variant,
                    :cpu_package, :init_pid

      def initialize(ct, load_conf: true)
        @ct = ct
        @dataset = ct.dataset
        @rootfs = ct.rootfs
        @distribution = ct.distribution
        @version = ct.version
        @arch = ct.arch
        @vendor = ct.vendor
        @variant = ct.variant
        @cpu_package = nil
        @save_calls = 0
        @destroy_calls = 0
        @retirement_calls = 0
        @retiring = false
        @retirement_complete = false
        @retirement_mutex = Mutex.new
        @retirement_cond = ConditionVariable.new
        @lifecycle_lease_count = 0
        @closed_lifecycle_lease_count = 0
        @destroy_observed_lease_count = nil
        @distribution_updates = []
        @load_conf = load_conf
      end

      def save
        @save_calls += 1
      end

      def destroy
        @retirement_mutex.synchronize do
          @retirement_cond.wait(@retirement_mutex) while @lifecycle_lease_count > 0

          @destroy_observed_lease_count = @lifecycle_lease_count
          @destroy_calls += 1
          @retirement_complete = true
          @retirement_cond.broadcast
        end
      end

      def begin_retirement
        @retirement_mutex.synchronize do
          @retirement_calls += 1
          return false if @retiring

          @retiring = true
          true
        end
      end

      def retiring?
        @retirement_mutex.synchronize { @retiring }
      end

      def wait_for_lifecycle_leases
        @retirement_mutex.synchronize do
          @retirement_cond.wait(@retirement_mutex) while @lifecycle_lease_count > 0
        end
      end

      def acquire_lifecycle_lease
        @retirement_mutex.synchronize do
          raise 'container run is retiring' if @retiring

          @lifecycle_lease_count += 1
        end

        run_conf = self
        closed = false
        close_mutex = Mutex.new
        Object.new.tap do |lease|
          lease.define_singleton_method(:close) do
            release = close_mutex.synchronize do
              next false if closed

              closed = true
              true
            end
            run_conf.__send__(:release_test_lifecycle_lease) if release
          end
        end
      end

      def wait_until_retired
        @retirement_mutex.synchronize do
          @retirement_cond.wait(@retirement_mutex) until @retirement_complete
        end
      end

      def release_test_lifecycle_lease
        @retirement_mutex.synchronize do
          @lifecycle_lease_count -= 1
          @closed_lifecycle_lease_count += 1
          @retirement_cond.broadcast
        end
      end

      def set_distribution(distribution:, version:, arch:, vendor:, variant:)
        @distribution = distribution
        @version = version
        @arch = arch
        @vendor = vendor
        @variant = variant
        @distribution_updates << {
          distribution:,
          version:,
          arch:,
          vendor:,
          variant:
        }
        save
      end
    end.tap do |klass|
      klass.const_set(:LifecycleError, Class.new(StandardError))
      klass.load_return = load_return
    end
  end

  def stub_container_runtime_classes(run_configuration_class: nil, hints_class: nil)
    app_armor_class = Class.new do
      attr_reader :ct

      def initialize(ct)
        @ct = ct
      end

      def dup(new_ct)
        self.class.new(new_ct)
      end
    end

    lxc_config_class = Class.new do
      attr_reader :ct

      def initialize(ct)
        @ct = ct
      end

      def configure; end
      def configure_base; end
      def configure_cgparams; end
      def configure_prlimits; end
      def configure_mounts; end
      def assets(_add); end

      def dup(new_ct)
        self.class.new(new_ct)
      end
    end

    net_interface_manager_class = Class.new do
      include Enumerable

      attr_reader :ct

      def self.load(ct, cfg, **_opts)
        entries = Array(cfg).map do |entry|
          if entry.respond_to?(:can_run_distconfig?)
            entry
          else
            ContainerHelpers::FakeNetInterface.new(
              can_run_distconfig: entry.fetch('can_run_distconfig', true)
            )
          end
        end

        new(ct, entries:)
      end

      def initialize(ct, entries: [])
        @ct = ct
        @entries = entries
      end

      def each(&block)
        @entries.each(&block)
      end

      def dump
        @entries.map(&:save)
      end

      def recovery_tainted?
        false
      end

      def setup_state_changed?
        false
      end

      def dup(new_ct)
        self.class.new(new_ct, entries: @entries.map { |entry| entry.dup(new_ct) })
      end
    end

    cgparams_class = Class.new do
      attr_reader :owner, :cfg
      attr_accessor :memory_limit, :swap_limit, :cpu_limit

      def self.load(owner, cfg)
        new(owner, cfg:)
      end

      def initialize(owner, cfg: nil)
        @owner = owner
        @cfg = cfg
        @memory_limit = nil
        @swap_limit = nil
        @cpu_limit = nil
      end

      def dump
        cfg || {}
      end

      def find_memory_limit
        memory_limit
      end

      def find_swap_limit
        swap_limit
      end

      def find_cpu_limit
        cpu_limit
      end

      def dup(new_owner)
        self.class.new(new_owner, cfg: cfg).tap do |ret|
          ret.memory_limit = memory_limit
          ret.swap_limit = swap_limit
          ret.cpu_limit = cpu_limit
        end
      end
    end

    devices_class = Class.new do
      attr_reader :owner, :cfg, :check_calls
      attr_accessor :init_calls, :ensure_all_calls, :remove_missing_calls

      def self.new_for(owner, **_kwargs)
        new(owner)
      end

      def self.load(owner, cfg)
        new(owner, cfg:)
      end

      def initialize(owner, cfg: nil)
        @owner = owner
        @cfg = cfg
        @init_calls = 0
        @ensure_all_calls = 0
        @remove_missing_calls = 0
        @check_calls = []
      end

      def init
        @init_calls += 1
      end

      def ensure_all
        @ensure_all_calls += 1
      end

      def remove_missing
        @remove_missing_calls += 1
      end

      def check_all_available!(group:)
        @check_calls << group
      end

      def dump
        cfg || []
      end

      def assets(_add); end

      def dup(new_owner)
        self.class.new(new_owner, cfg: cfg)
      end
    end

    prlimits_class = Class.new do
      attr_reader :ct, :cfg

      def self.default(ct)
        new(ct)
      end

      def self.load(ct, cfg)
        new(ct, cfg:)
      end

      def initialize(ct, cfg: nil)
        @ct = ct
        @cfg = cfg
      end

      def dump
        cfg || {}
      end

      def dup(new_ct)
        self.class.new(new_ct, cfg:)
      end
    end

    mount_manager_class = Class.new do
      attr_reader :ct, :cfg, :shared_dir

      def self.load(ct, cfg)
        new(ct, cfg:)
      end

      def initialize(ct, cfg: nil)
        @ct = ct
        @cfg = cfg
        @shared_dir = ContainerHelpers::FakeSharedDir.new(
          path: File.join(ct.lxc_dir, 'shared'),
          mountpoint: 'shared'
        )
      end

      def dump
        cfg || []
      end

      def dup(new_ct)
        self.class.new(new_ct, cfg:)
      end
    end

    cpu_daily_class = Struct.new(:user_us, :system_us, keyword_init: true) do
      def usage_us
        user_us + system_us
      end

      def dump
        {
          'user_us' => user_us,
          'system_us' => system_us
        }
      end
    end

    hints_class ||= Class.new do
      define_singleton_method(:cpu_daily_class) { cpu_daily_class }

      attr_reader :ct, :cpu_daily, :account_calls

      def self.load(ct, _cfg)
        new(ct)
      end

      def initialize(ct)
        @ct = ct
        @cpu_daily = self.class.cpu_daily_class.new(user_us: 0, system_us: 0)
        @account_calls = 0
      end

      def account_cpu_use
        @account_calls += 1
      end

      def dump
        {
          'cpu_daily' => cpu_daily.dump
        }
      end

      def dup(new_ct)
        self.class.new(new_ct)
      end
    end

    dist_config_module = Module.new do
      def self.run(*); end
    end

    erb_template_class = Class.new do
      def self.render_to(*); end
    end

    send_log_class = Class.new do
      attr_reader :role, :token, :state, :snapshots, :opts

      def self.load(cfg)
        new(
          role: cfg['role'].to_sym,
          token: cfg['token'],
          state: (cfg['state'] || 'stage').to_sym,
          snapshots: cfg['snapshots'] || [],
          opts: cfg['opts'] || {}
        )
      end

      def initialize(role:, token:, opts:, state: :stage, snapshots: [])
        @role = role
        @token = token
        @opts = opts
        @state = state
        @snapshots = snapshots
      end

      def dump
        {
          'role' => role.to_s,
          'token' => token,
          'state' => state.to_s,
          'snapshots' => snapshots,
          'opts' => opts
        }
      end

      def close; end
    end

    tokens_module = Module.new do
      def self.register(_token); end

      def self.free(_token); end
    end

    stub_const('OsCtld::AppArmor', app_armor_class)
    stub_const('OsCtld::Container::LxcConfig', lxc_config_class)
    stub_const('OsCtld::NetInterface::Manager', net_interface_manager_class)
    stub_const('OsCtld::CGroup::ContainerParams', cgparams_class)
    stub_const('OsCtld::Devices::Manager', devices_class)
    stub_const('OsCtld::PrLimits::Manager', prlimits_class)
    stub_const('OsCtld::Mount::Manager', mount_manager_class)
    stub_const('OsCtld::DistConfig', dist_config_module)
    stub_const('OsCtld::ErbTemplate', erb_template_class)
    stub_const('OsCtld::SendReceive::Log', send_log_class)
    stub_const('OsCtld::SendReceive::Tokens', tokens_module)
    stub_const('OsCtld::Container::Hints', hints_class)
    stub_const('OsCtld::Container::RunConfiguration', run_configuration_class) if run_configuration_class

    {
      app_armor_class:,
      lxc_config_class:,
      net_interface_manager_class:,
      cgparams_class:,
      devices_class:,
      prlimits_class:,
      mount_manager_class:,
      hints_class:,
      send_log_class:
    }
  end
end

RSpec.configure do |config|
  config.include ContainerHelpers
end
