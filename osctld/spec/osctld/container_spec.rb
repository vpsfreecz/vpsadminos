# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/attributes'
require 'osctld/auto_start/config'

module OsCtld
  module Utils; end unless const_defined?(:Utils)
end

require 'osctld/utils/switch_user'
require 'osctld/container/adaptor'
require 'osctld/container/raw_configs'
require 'osctld/container/impermanence'
require 'osctld/container/start_menu'
require 'osctld/container'

RSpec.describe OsCtld::Container do
  let(:run_conf_class) { build_fake_run_configuration_class(load_return: nil) }
  let(:runtime) { stub_container_runtime_classes(run_configuration_class: run_conf_class) }

  before do
    OsCtld::Container::Adaptor.instance_variable_set(:@adaptors, nil)
    runtime
    allow(File).to receive(:chown).and_return(0)

    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Error', Class.new(StandardError))
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct)
        Struct.new(:state, :init_pid).new(:running, nil)
      end
    end)
  end

  def build_container(root:, **opts)
    build_container_fixture(root:, **opts)
  end

  def build_configured_container(root:, **opts)
    ct = build_container(root:, **opts)
    ct.configure('almalinux', '9', 'x86_64')
    ct
  end

  describe 'initialization and paths' do
    it 'requires user and group when load is disabled' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)

        expect do
          described_class.new(pool, 'ct1', nil, nil, nil, load: false)
        end.to raise_error(ArgumentError, /either set load: true or provide user and group/)
      end
    end

    it 'builds container identifiers and filesystem paths' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)

        expect(ct.ident).to eq('tank:ct1')
        expect(ct.config_path).to eq(File.join(ct.pool.conf_path, 'ct', 'ct1.yml'))
        expect(ct.log_path).to eq(File.join(ct.pool.log_path, 'ct', 'ct1.log'))
        expect(ct.lxc_home).to eq(File.join(ct.user.userdir, 'group.default', 'cts'))
        expect(ct.lxc_dir).to eq(File.join(ct.lxc_home, 'ct1'))
        expect(ct.base_cgroup_path).to eq('/osctl/pool.tank/group.default/user.alice/ct.ct1')
        expect(ct.cgroup_path).to eq('/osctl/pool.tank/group.default/user.alice/ct.ct1/user-owned')
        expect(ct.entry_cgroup_path).to eq('/osctl/pool.tank/group.default/user.alice/ct.ct1/user-owned/lxc.monitor.ct1')
        expect(ct.payload_cgroup_path).to eq('/osctl/pool.tank/group.default/user.alice/ct.ct1/user-owned/lxc.payload.ct1')
        expect(ct.attach_cgroup_path).to eq('/osctl/pool.tank/group.default/user.alice/ct.ct1/user-owned/lxc.payload.ct1/osctl.attach')
      end
    end

    it 'builds default datasets under pool.ct_ds' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)

        expect(described_class.default_dataset(pool, 'ct1').name).to eq('tank/ct/ct1')
      end
    end

    it 'returns nil from rootfs when the dataset mountpoint lookup fails' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        user = FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
        group = FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
        dataset = Object.new
        dataset.define_singleton_method(:mountpoint) do
          raise OsCtld::SystemCommandFailed.new('zfs mount', 1, 'boom')
        end

        ct = described_class.new(pool, 'ct1', user, group, dataset, load: false)

        expect(ct.rootfs).to be_nil
      end
    end

    it 'loads config via the registries and enables start menu by default' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        user = FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
        group = FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
        stub_users_registry([user])
        stub_groups_registry([group], root: group)

        ct = described_class.new(
          pool,
          'ct1',
          nil,
          nil,
          nil,
          load_from: dump_yaml(
            'user' => 'alice',
            'group' => '/default',
            'dataset' => 'tank/ct/ct1',
            'map_mode' => 'zfs',
            'distribution' => 'almalinux',
            'version' => '9',
            'arch' => 'x86_64',
            'vendor' => 'default',
            'variant' => 'default',
            'net_interfaces' => [],
            'cgparams' => {},
            'devices' => [],
            'prlimits' => {},
            'mounts' => {},
            'attrs' => {}
          ),
          devices: false
        )

        expect(ct.user).to eq(user)
        expect(ct.group).to eq(group)
        expect(ct.start_menu).to be_a(OsCtld::Container::StartMenu)
      end
    end
  end

  describe '#syslogns_tag' do
    it 'keeps the legacy stable tag by default' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: 'ct1')

        expect(ct.syslogns_tag).to eq('    tank:ct1')
      end
    end

    it 'adds a run-specific suffix when a run id is provided' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: 'long-container-name')
        run_id = double(to_s: 'tank:long-container-name:123.45')

        tag = ct.syslogns_tag(run_id:)

        expect(tag.bytesize).to eq(OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE)
        expect(tag).to match(/\Along-co:[0-9a-f]{4}\z/)
      end
    end
  end

  describe '#configure' do
    it 'initializes runtime managers, creates a run configuration, and saves config' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)

        ct.configure('ubuntu', '24.04', 'x86_64')

        expect(ct.distribution).to eq('ubuntu')
        expect(ct.version).to eq('24.04')
        expect(ct.arch).to eq('x86_64')
        expect(ct.netifs).to be_a(runtime[:net_interface_manager_class])
        expect(ct.cgparams).to be_a(runtime[:cgparams_class])
        expect(ct.devices).to be_a(runtime[:devices_class])
        expect(ct.prlimits).to be_a(runtime[:prlimits_class])
        expect(ct.mounts).to be_a(runtime[:mount_manager_class])
        expect(ct.seccomp_profile).to eq('/etc/lxc/config/common.seccomp')
        expect(ct.run_conf).to be_a(run_conf_class)
        expect(ct.devices.init_calls).to eq(1)
        expect(load_yaml_file(ct.config_path)).to include(
          'distribution' => 'ubuntu',
          'version' => '24.04',
          'arch' => 'x86_64'
        )
      end
    end
  end

  describe 'run configuration lifecycle' do
    it 'creates new runtime configurations on demand' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)

        expect(ct.new_run_conf).to be_a(run_conf_class)
      end
    end

    it 'returns the active run configuration from get_run_conf' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', active)

        expect(ct.get_run_conf).to eq(active)
      end
    end

    it 'builds an ephemeral run configuration when none is active' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)

        generated = ct.get_run_conf

        expect(generated).to be_a(run_conf_class)
        expect(ct.run_conf).to be_nil
      end
    end

    it 'uses next_run_conf during init_run_conf, saves it, and reconfigures' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        next_run_conf = run_conf_class.new(ct, load_conf: false)
        ct.set_next_run_conf(next_run_conf)
        allow(ct).to receive(:reconfigure)

        ct.init_run_conf

        expect(ct.run_conf).to eq(next_run_conf)
        expect(ct.next_run_conf).to be_nil
        expect(next_run_conf.save_calls).to eq(1)
        expect(ct).to have_received(:reconfigure)
      end
    end

    it 'initializes a run configuration only once in ensure_run_conf' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        allow(ct).to receive(:reconfigure)

        first = ct.ensure_run_conf
        second = ct.ensure_run_conf

        expect(first).to eq(second)
        expect(first.save_calls).to eq(1)
      end
    end

    it 'moves the active run configuration to past_run_conf when stopped' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', active)

        ct.stopped

        expect(active.destroy_calls).to eq(1)
        expect(ct.run_conf).to be_nil
        expect(ct.get_past_run_conf).to eq(active)
      end
    end

    it 'forgets the past runtime configuration' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        ct.instance_variable_set('@past_run_conf', run_conf_class.new(ct, load_conf: false))

        ct.forget_past_run_conf

        expect(ct.get_past_run_conf).to be_nil
      end
    end
  end

  describe 'mount state caching' do
    it 'uses cached mount state between forced checks and updates it on mount/unmount' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        allow(ct.dataset).to receive(:mounted?).and_call_original
        allow(ct.dataset).to receive(:mount).and_call_original
        allow(ct.dataset).to receive(:unmount).and_call_original

        expect(ct.mounted?(force: true)).to be(false)
        expect(ct.mounted?(force: false)).to be(false)
        expect(ct.dataset).to have_received(:mounted?).once

        ct.mount
        ct.mount
        ct.unmount

        expect(ct.dataset).to have_received(:mount).once
        expect(ct.dataset).to have_received(:unmount).once
        expect(ct.mounted?(force: false)).to be(false)
      end
    end
  end

  describe 'ownership changes' do
    it 'saves and reconfigures when map_mode changes' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        allow(ct.lxc_config).to receive(:configure)

        ct.map_mode = 'native'

        expect(ct.map_mode).to eq('native')
        expect(ct.lxc_config).to have_received(:configure)
        expect(load_yaml_file(ct.config_path)['map_mode']).to eq('native')
      end
    end

    it 'saves, reconfigures, and regenerates bashrc when chowning' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        new_user = FakeObjects::FakeUser.new(name: 'bob', userdir: File.join(ct.pool.user_dir, 'bob'))
        FileUtils.mkdir_p(new_user.userdir)
        allow(ct.lxc_config).to receive(:configure)
        allow(OsCtld::ErbTemplate).to receive(:render_to)

        ct.chown(new_user)

        expect(ct.user).to eq(new_user)
        expect(ct.lxc_config).to have_received(:configure)
        expect(OsCtld::ErbTemplate).to have_received(:render_to).with(
          'ct/bashrc',
          hash_including(ct: ct),
          File.join(ct.lxc_dir, '.bashrc')
        )
        expect(load_yaml_file(ct.config_path)['user']).to eq('bob')
      end
    end

    it 'provides missing devices on chgrp with missing_devices=provide' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        new_group = FakeObjects::FakeGroup.new(name: '/ops', cgroup_path: '/osctl/pool.tank/group.ops')
        allow(ct.lxc_config).to receive(:configure)
        allow(OsCtld::ErbTemplate).to receive(:render_to)

        ct.chgrp(new_group, missing_devices: 'provide')

        expect(ct.group).to eq(new_group)
        expect(ct.devices.ensure_all_calls).to eq(1)
        expect(ct.devices.init_calls).to eq(2)
        expect(ct.lxc_config).to have_received(:configure)
      end
    end

    it 'removes missing devices on chgrp with missing_devices=remove' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        new_group = FakeObjects::FakeGroup.new(name: '/ops', cgroup_path: '/osctl/pool.tank/group.ops')

        ct.chgrp(new_group, missing_devices: 'remove')

        expect(ct.devices.remove_missing_calls).to eq(1)
        expect(ct.devices.init_calls).to eq(2)
      end
    end

    it 'checks missing devices on chgrp with missing_devices=check' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        new_group = FakeObjects::FakeGroup.new(name: '/ops', cgroup_path: '/osctl/pool.tank/group.ops')

        ct.chgrp(new_group, missing_devices: 'check')

        expect(ct.devices.check_calls).to eq([new_group])
        expect(ct.devices.init_calls).to eq(1)
      end
    end

    it 'rejects unsupported missing_devices actions' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        new_group = FakeObjects::FakeGroup.new(name: '/ops', cgroup_path: '/osctl/pool.tank/group.ops')

        expect do
          ct.chgrp(new_group, missing_devices: 'explode')
        end.to raise_error(RuntimeError, /unsupported action/)
      end
    end
  end

  describe 'state transitions and runtime freshness' do
    it 'persists staged complete and running transitions' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, staged: true)
        ct.configure('almalinux', '9', 'x86_64')
        ct.instance_variable_set('@state', :staged)

        ct.state = :complete
        expect(ct.state).to eq(:stopped)

        ct.instance_variable_set('@state', :staged)
        ct.state = :running
        expect(ct.state).to eq(:running)
      end
    end

    it 'updates non-staged state directly and reports running?' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)

        ct.state = :running

        expect(ct.running?).to be(true)
      end
    end

    it 'refuses starts for staged, error, and inactive pools' do
      with_tmpdir do |dir|
        staged = build_container(root: dir, staged: true)
        errored = build_container(root: File.join(dir, 'error'))
        inactive = build_container(root: File.join(dir, 'inactive'))

        errored.state = :error
        allow(inactive.pool).to receive(:active?).and_return(false)

        expect(staged.can_start?).to be(false)
        expect(errored.can_start?).to be(false)
        expect(inactive.can_start?).to be(false)
      end
    end

    it 'queries runtime state only when state is unknown' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).and_return(
          Struct.new(:state, :init_pid).new(:running, nil)
        )

        expect(ct.fresh_state).to eq(:running)
        expect(OsCtld::ContainerControl::Commands::State).to have_received(:run!).once

        ct.state = :stopped
        expect(ct.fresh_state).to eq(:stopped)
        expect(OsCtld::ContainerControl::Commands::State).to have_received(:run!).once
      end
    end

    it 'stores init_pid returned while refreshing runtime state' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).and_return(
          Struct.new(:state, :init_pid).new(:running, 4321)
        )

        expect(ct.current_state).to eq(:running)
        expect(ct.init_pid).to eq(4321)
      end
    end

    it 'recovers a missing init_pid when exporting a running container' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        ct.state = :running
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).and_return(
          Struct.new(:state, :init_pid).new(:running, 5678)
        )

        expect(ct.export[:init_pid]).to eq(5678)
      end
    end

    it 'stores :error when current_state raises ContainerControl::Error' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).and_raise(
          OsCtld::ContainerControl::Error,
          'boom'
        )

        expect(ct.current_state).to eq(:error)
        expect(ct.state).to eq(:error)
      end
    end
  end

  describe 'limit lookup' do
    it 'prefers local limits and falls back to the group when needed' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)

        ct.cgparams.memory_limit = 512
        ct.group.swap_limit = 2_048
        ct.group.cpu_limit = 300

        expect(ct.find_memory_limit).to eq(512)
        expect(ct.find_swap_limit).to eq(2_048)
        expect(ct.find_cpu_limit).to eq(300)
      end
    end

    it 'returns nil without parent lookup when no local limit is set' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        ct.group.memory_limit = 1_024

        expect(ct.find_memory_limit(parents: false)).to be_nil
        expect(ct.find_swap_limit(parents: false)).to be_nil
        expect(ct.find_cpu_limit(parents: false)).to be_nil
      end
    end

    it 'handles containers before cgroup params are configured' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        ct.group.memory_limit = 1_024

        expect(ct.cgparams).to be_nil
        expect(ct.find_memory_limit).to eq(1_024)
        expect(ct.find_memory_limit(parents: false)).to be_nil
        expect(ct.find_swap_limit).to be_nil
        expect(ct.find_cpu_limit).to be_nil
      end
    end
  end

  describe '#set and #unset' do
    it 'sets hostname and dns resolvers and asks dist config to update them' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        allow(OsCtld::DistConfig).to receive(:run)
        allow(ct.lxc_config).to receive(:configure_base)

        ct.set(
          hostname: 'web1.example.com',
          dns_resolvers: ['1.1.1.1', '8.8.8.8']
        )

        expect(ct.hostname.to_s).to eq('web1.example.com')
        expect(ct.dns_resolvers).to eq(%w[1.1.1.1 8.8.8.8])
        expect(OsCtld::DistConfig).to have_received(:run).with(
          instance_of(run_conf_class),
          :set_hostname,
          original: nil
        )
        expect(OsCtld::DistConfig).to have_received(:run).with(
          instance_of(run_conf_class),
          :dns_resolvers
        )
        expect(ct.lxc_config).to have_received(:configure_base)
      end
    end

    it 'updates the active run configuration when distribution changes' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', active)

        ct.set(
          distribution: {
            name: 'nixos',
            version: '24.11',
            arch: 'aarch64',
            vendor: 'custom',
            variant: 'minimal'
          }
        )

        expect(ct.distribution).to eq('nixos')
        expect(active.distribution_updates).to eq(
          [
            {
              distribution: 'nixos',
              version: '24.11',
              arch: 'aarch64',
              vendor: 'custom',
              variant: 'minimal'
            }
          ]
        )
      end
    end

    it 'sets persisted container options and value objects' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        allow(ct.lxc_config).to receive(:configure_base)

        ct.set(
          autostart: { priority: 10, delay: 5 },
          ephemeral: true,
          nesting: true,
          cpu_package: 2,
          seccomp_profile: '/custom.seccomp',
          init_cmd: ['/sbin/custom-init'],
          start_menu: { timeout: 15 },
          impermanence: { zfs_properties: { backup: 'false' } },
          raw_lxc: 'lxc.include = custom.conf',
          attrs: { 'org.vpsfree.cz/test:role' => 'system' }
        )

        expect(ct.autostart.priority).to eq(10)
        expect(ct.autostart.delay).to eq(5)
        expect(ct.ephemeral?).to be(true)
        expect(ct.nesting).to be(true)
        expect(ct.cpu_package).to eq(2)
        expect(ct.seccomp_profile).to eq('/custom.seccomp')
        expect(ct.init_cmd).to eq(['/sbin/custom-init'])
        expect(ct.start_menu.timeout).to eq(15)
        expect(ct.impermanence.zfs_properties).to eq('backup' => 'false')
        expect(ct.raw_configs.lxc).to eq('lxc.include = custom.conf')
        expect(ct.attrs['org.vpsfree.cz/test:role']).to eq('system')
        expect(ct.lxc_config).to have_received(:configure_base)
      end
    end

    it 'unsets persisted options and notifies autostart and dist config' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        allow(ct.pool.autostart_plan).to receive(:stop_ct)
        allow(OsCtld::DistConfig).to receive(:run)
        allow(ct.lxc_config).to receive(:configure_base)

        ct.set(
          autostart: { priority: 10, delay: 5 },
          hostname: 'web1.example.com',
          dns_resolvers: ['1.1.1.1'],
          nesting: true,
          cpu_package: 2,
          seccomp_profile: '/custom.seccomp',
          init_cmd: ['/sbin/custom-init'],
          start_menu: { timeout: 15 },
          impermanence: { zfs_properties: { backup: 'false' } },
          raw_lxc: 'lxc.include = custom.conf',
          attrs: { 'org.vpsfree.cz/test:role' => 'system' }
        )

        run_conf = ct.get_run_conf
        ct.unset(
          autostart: true,
          hostname: true,
          dns_resolvers: true,
          nesting: true,
          cpu_package: true,
          seccomp_profile: true,
          init_cmd: true,
          start_menu: true,
          impermanence: true,
          raw_lxc: true,
          attrs: ['org.vpsfree.cz/test:role']
        )

        expect(ct.autostart).to be(false)
        expect(ct.hostname).to be_nil
        expect(ct.dns_resolvers).to be_nil
        expect(ct.nesting).to be(false)
        expect(ct.cpu_package).to eq('auto')
        expect(ct.seccomp_profile).to eq('/etc/lxc/config/common.seccomp')
        expect(ct.init_cmd).to be_nil
        expect(ct.start_menu).to be_nil
        expect(ct.impermanence).to be_nil
        expect(ct.raw_configs.lxc).to be_nil
        expect(ct.attrs.dump).to eq({})
        expect(ct.pool.autostart_plan).to have_received(:stop_ct).with(ct)
        expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :unset_etc_hosts)
        expect(ct.lxc_config).to have_received(:configure_base).twice
      end
    end
  end
end
