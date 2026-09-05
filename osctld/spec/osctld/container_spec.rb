# frozen_string_literal: true

require 'timeout'
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
require 'osctld/container/recovery'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_post_stop'

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

    it 'persists a running old-config host-link migration after installing the manager' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        user = FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
        group = FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
        stub_users_registry([user])
        stub_groups_registry([group], root: group)
        manager_class = runtime[:net_interface_manager_class]
        allow(manager_class).to receive(:load) do |ct, _cfg, discover_host_links:|
          expect(discover_host_links).to be(true)
          manager = manager_class.new(ct)
          manager.define_singleton_method(:setup_state_changed?) { true }
          manager.define_singleton_method(:dump) do
            raise 'manager was not installed before migration save' unless ct.netifs.equal?(self)

            [
              {
                'type' => 'bridge',
                'name' => 'eth0',
                'host_link' => {
                  'name' => 'veth0',
                  'ifindex' => 10,
                  'ifb_ifindex' => nil,
                  'tainted' => false
                }
              }
            ]
          end
          manager
        end

        config = {
          'user' => 'alice',
          'group' => '/default',
          'dataset' => 'tank/ct/ct1',
          'map_mode' => 'zfs',
          'distribution' => 'almalinux',
          'version' => '9',
          'arch' => 'x86_64',
          'net_interfaces' => [{ 'type' => 'bridge', 'name' => 'eth0' }],
          'cgparams' => {},
          'devices' => [],
          'prlimits' => {},
          'mounts' => {},
          'attrs' => {}
        }
        write_yaml_file(File.join(pool.conf_path, 'ct', 'ct1.yml'), config)

        ct = described_class.new(
          pool,
          'ct1',
          nil,
          nil,
          nil,
          devices: false
        )

        expect(load_yaml_file(ct.config_path).dig('net_interfaces', 0, 'host_link')).to eq(
          'name' => 'veth0',
          'ifindex' => 10,
          'ifb_ifindex' => nil,
          'tainted' => false
        )
      end
    end

    it 'strips an imported host-link identity before manager load' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        user = FakeObjects::FakeUser.new(name: 'alice', userdir: File.join(pool.user_dir, 'alice'))
        group = FakeObjects::FakeGroup.new(name: '/default', cgroup_path: '/osctl/pool.tank/group.default')
        stub_users_registry([user])
        stub_groups_registry([group], root: group)
        manager_class = runtime[:net_interface_manager_class]
        loaded_netifs = nil
        allow(manager_class).to receive(:load) do |ct, cfg, discover_host_links:|
          expect(discover_host_links).to be(false)
          loaded_netifs = cfg
          manager_class.new(ct)
        end

        imported = described_class.new(
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
            'state' => 'error',
            'net_interfaces' => [
              {
                'type' => 'bridge',
                'name' => 'eth0',
                'host_link' => {
                  'name' => 'foreign0',
                  'ifindex' => 42,
                  'ifb_ifindex' => 43,
                  'tainted' => false
                }
              }
            ],
            'cgparams' => {},
            'devices' => [],
            'prlimits' => {},
            'mounts' => {},
            'attrs' => {}
          ),
          devices: false
        )

        expect(loaded_netifs.first).not_to have_key('host_link')
        expect(imported.state).to eq(:unknown)
      end
    end

    it 'trusts runtime metadata only from the exact daemon config path' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        other_path = File.join(dir, 'other-container.yml')
        write_yaml_file(other_path, ct.dump_config.merge('state' => 'error'))

        expect do
          ct.send(:load_config_file, other_path)
        end.to raise_error(ArgumentError)
        allow(OsCtl::Lib::ConfigFile).to receive(:load_yaml_file).and_call_original

        ct.reload_config

        expect(OsCtl::Lib::ConfigFile).to have_received(:load_yaml_file).with(ct.config_path)
        expect(ct.state).not_to eq(:error)
      end
    end

    it 'ignores replacement host-link authority and preserves the daemon record' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        manager_class = runtime[:net_interface_manager_class]
        internal_host_link = {
          'name' => 'veth0',
          'ifindex' => 10,
          'ifb_ifindex' => 20,
          'tainted' => true
        }
        current_netif = ContainerHelpers::FakeHostLinkNetInterface.new(
          type: :bridge,
          name: 'eth0',
          identity: ['veth0', 10, 20],
          tainted: true,
          saved: {
            'type' => 'bridge',
            'name' => 'eth0',
            'host_link' => internal_host_link
          }
        )
        ct.instance_variable_set(
          :@netifs,
          manager_class.new(ct, entries: [current_netif])
        )
        ct.state = :error
        replacement = ct.dump_config
        replacement['state'] = 'running'
        replacement['net_interfaces'].first['host_link'] = {
          'name' => 'foreign0',
          'ifindex' => 42,
          'ifb_ifindex' => 43,
          'tainted' => false
        }
        loaded_netifs = nil
        allow(manager_class).to receive(:load) do |owner, cfg, discover_host_links:|
          expect(discover_host_links).to be(false)
          loaded_netifs = cfg
          manager_class.new(owner)
        end

        ct.replace_config(dump_yaml(replacement))

        expect(loaded_netifs.first['host_link']).to eq(internal_host_link)
        expect(ct.state).to eq(:error)
      end
    end

    it 'rejects discarding or renaming a clean stopped host-link owner' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        manager_class = runtime[:net_interface_manager_class]
        current_netif = ContainerHelpers::FakeHostLinkNetInterface.new(
          type: :bridge,
          name: 'eth0',
          identity: ['veth0', 10, nil],
          tainted: false,
          saved: {
            'type' => 'bridge',
            'name' => 'eth0',
            'host_link' => {
              'name' => 'veth0',
              'ifindex' => 10,
              'ifb_ifindex' => nil,
              'tainted' => false
            }
          }
        )
        manager = manager_class.new(ct, entries: [current_netif])
        ct.instance_variable_set(:@netifs, manager)
        ct.state = :stopped

        removed = ct.dump_config.merge('net_interfaces' => [])
        renamed = ct.dump_config
        renamed['net_interfaces'].first['name'] = 'eth1'

        expect do
          ct.replace_config(dump_yaml(removed))
        end.to raise_error(
          OsCtld::ConfigError,
          %r{cannot discard internal host-link owners: bridge/eth0}
        )
        expect do
          ct.replace_config(dump_yaml(renamed))
        end.to raise_error(
          OsCtld::ConfigError,
          %r{cannot discard internal host-link owners: bridge/eth0}
        )
        expect(ct.netifs).to be(manager)
        expect(ct.state).to eq(:stopped)
      end
    end

    it 'rejects duplicating a retained host-link owner in external config' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        manager_class = runtime[:net_interface_manager_class]
        current_netif = ContainerHelpers::FakeHostLinkNetInterface.new(
          type: :bridge,
          name: 'eth0',
          identity: ['veth0', 10, nil],
          tainted: false,
          saved: {
            'type' => 'bridge',
            'name' => 'eth0',
            'host_link' => {
              'name' => 'veth0',
              'ifindex' => 10,
              'ifb_ifindex' => nil,
              'tainted' => false
            }
          }
        )
        ct.instance_variable_set(
          :@netifs,
          manager_class.new(ct, entries: [current_netif])
        )
        replacement = ct.dump_config
        duplicate = replacement['net_interfaces'].first.dup
        duplicate['host_link'] = duplicate['host_link'].dup
        replacement['net_interfaces'] << duplicate

        expect do
          ct.replace_config(dump_yaml(replacement))
        end.to raise_error(
          OsCtld::ConfigError,
          %r{duplicates internal host-link owner bridge/eth0}
        )
      end
    end

    it 'serializes replacement authority snapshots with lifecycle state changes' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        manager_class = runtime[:net_interface_manager_class]
        identity_read = Queue.new
        release_identity = Queue.new
        state_changed = Queue.new
        current_netif = ContainerHelpers::FakeHostLinkNetInterface.new(
          type: :bridge,
          name: 'eth0',
          identity: ['veth0', 10, nil],
          tainted: false,
          saved: {
            'type' => 'bridge',
            'name' => 'eth0',
            'host_link' => {
              'name' => 'veth0',
              'ifindex' => 10,
              'ifb_ifindex' => nil,
              'tainted' => false
            }
          }
        )
        allow(current_netif).to receive(:host_link_identity) do
          identity_read << true
          Timeout.timeout(5) { release_identity.pop }
          ['veth0', 10, nil]
        end
        ct.instance_variable_set(
          :@netifs,
          manager_class.new(ct, entries: [current_netif])
        )
        replacement = ct.dump_config

        replace_thread = Thread.new { ct.replace_config(dump_yaml(replacement)) }
        Timeout.timeout(5) { identity_read.pop }
        state_thread = Thread.new do
          ct.state = :running
          state_changed << true
        end

        expect { state_changed.pop(true) }.to raise_error(ThreadError)
        expect(state_thread).to be_alive

        release_identity << true
        expect(replace_thread.join(5)).to be(replace_thread)
        expect(state_thread.join(5)).to be(state_thread)
        expect { replace_thread.value }.not_to raise_error
        expect { state_thread.value }.not_to raise_error
        expect(state_changed.pop).to be(true)
        expect(ct.state).to eq(:running)
      ensure
        release_identity&.push(true) if replace_thread&.alive?
        replace_thread&.join(5)
        state_thread&.join(5)
      end
    end

    it 'waits for the host-link registry before locking replacement state' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)
        manager_class = runtime[:net_interface_manager_class]
        current_netif = ContainerHelpers::FakeHostLinkNetInterface.new(
          type: :bridge,
          name: 'eth0',
          identity: ['veth0', 10, nil],
          tainted: false,
          saved: {
            'type' => 'bridge',
            'name' => 'eth0',
            'host_link' => {
              'name' => 'veth0',
              'ifindex' => 10,
              'ifb_ifindex' => nil,
              'tainted' => false
            }
          }
        )
        ct.instance_variable_set(
          :@netifs,
          manager_class.new(ct, entries: [current_netif])
        )
        replacement = ct.dump_config
        allow(manager_class).to receive(:load) do |owner, _cfg, **|
          OsCtld::NetInterface.sync_host_link_registry { true }
          manager_class.new(owner)
        end

        replace_started = Queue.new
        state_changed = Queue.new
        replace_thread = nil
        state_thread = nil

        OsCtld::NetInterface.sync_host_link_registry do
          replace_thread = Thread.new do
            replace_started << true
            ct.replace_config(dump_yaml(replacement))
          end
          replace_started.pop
          expect(replace_thread.join(0.05)).to be_nil

          state_thread = Thread.new do
            ct.state = :running
            state_changed << true
          end
          expect(state_thread.join(5)).to be(state_thread)
          expect(state_changed.pop).to be(true)
        end

        expect(replace_thread.join(5)).to be(replace_thread)
        expect { replace_thread.value }.not_to raise_error
        expect(ct.state).to eq(:running)
      ensure
        replace_thread&.join(5)
        state_thread&.join(5)
      end
    end
  end

  describe '#syslogns_tag' do
    it 'keeps a stable kernel-valid tag by default' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: 'ct1')

        expect(ct.syslogns_tag).to eq('tank_ct1')
      end
    end

    it 'adds a run-specific suffix when a run id is provided' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: 'long-container-name')
        run_id = 'tank:long-container-name:123.45'

        tag = ct.syslogns_tag(run_id:)

        expect(tag.bytesize).to eq(OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE)
        expect(tag).to match(/\Along-co-[0-9a-f]{4}\z/)
      end
    end

    it 'keeps every tag inside the kernel name grammar' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: '.-_container_-.')
        tags = [ct.syslogns_tag, ct.syslogns_tag(run_id: 'tank:.-_container_-.:123.45')]
        grammar = /\A[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\z/

        tags.each do |tag|
          expect(tag.bytesize).to be_between(1, OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE)
          expect(tag).to match(grammar)
        end
      end
    end

    it 'falls back to an alphanumeric prefix for an unusable container id' do
      with_tmpdir do |dir|
        ct = build_container(root: dir, id: '.-_.')

        expect(ct.syslogns_tag(run_id: 'tank:.-_.:123.45')).to match(/\Act-[0-9a-f]{4}\z/)
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

  describe 'transfer log persistence' do
    let(:local_transfer_opts) do
      {
        operation: :copy,
        target_pool: 'tank',
        target_id: 'ct1-copy',
        target_dataset: 'tank/ct/ct1-copy',
        target_dataset_custom: false,
        target_user: 'alice',
        target_group: '/default',
        network_interfaces: true,
        datasets: [
          OsCtld::LocalTransfer::Log::Dataset.new(
            relative_name: '/',
            source: 'tank/ct/ct1',
            target: 'tank/ct/ct1-copy'
          )
        ]
      }
    end

    it 'saves and loads local transfer logs' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        ct = build_configured_container(root: dir, pool:)

        ct.open_local_transfer_log(:source, local_transfer_opts)

        cfg = load_yaml_file(ct.config_path)
        expect(cfg['local_transfer_log']['opts']).to include(
          'operation' => 'copy',
          'target_id' => 'ct1-copy'
        )

        loaded = build_container(
          root: dir,
          pool:,
          load: true,
          load_from: dump_yaml(cfg),
          devices: false
        )

        expect(loaded.local_transfer_log.dump).to eq(ct.local_transfer_log.dump)
      end
    end

    it 'clears local transfer logs and reports transfer state' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)

        expect(ct.transfer_in_progress?).to be(false)
        expect(ct.transfer_log).to be_nil

        ct.open_local_transfer_log(:source, local_transfer_opts)

        expect(ct.transfer_in_progress?).to be(true)
        expect(ct.transfer_log).to eq(ct.local_transfer_log)

        ct.close_local_transfer_log

        expect(ct.local_transfer_log).to be_nil
        expect(load_yaml_file(ct.config_path)).not_to have_key('local_transfer_log')
      end
    end

    it 'reports send logs through transfer helpers' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)

        ct.open_send_log(:source, 'token-1', ctid: 'ct1', port: 22, dst: 'node')

        expect(ct.transfer_in_progress?).to be(true)
        expect(ct.transfer_log).to eq(ct.send_log)
      end
    end

    it 'clears send and local transfer logs on clone' do
      with_tmpdir do |dir|
        ct = build_configured_container(root: dir)

        ct.open_send_log(:source, 'token-1', ctid: 'ct1', port: 22, dst: 'node')
        ct.open_local_transfer_log(:source, local_transfer_opts)

        clone = ct.dup('ct1-copy')

        expect(clone.send_log).to be_nil
        expect(clone.local_transfer_log).to be_nil
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

    it 'atomically initializes one run configuration for concurrent ensure callers' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        original_init = ct.method(:init_run_conf)
        init_arrivals = Queue.new
        release_init = Queue.new
        created = []
        created_lock = Mutex.new
        results = Queue.new

        ct.define_singleton_method(:init_run_conf) do |*args, **kwargs|
          init_arrivals << true
          release_init.pop
          original_init.call(*args, **kwargs)
        end
        allow(ct).to receive(:new_run_conf).and_wrap_original do |original|
          run_conf = original.call
          created_lock.synchronize { created << run_conf }
          run_conf
        end
        allow(ct).to receive(:reconfigure)

        threads = 2.times.map do
          Thread.new { results << ct.ensure_run_conf }
        end
        2.times { init_arrivals.pop }
        2.times { release_init << true }
        threads.each { |thread| expect(thread.join(1)).to be(thread) }

        returned = 2.times.map { results.pop }
        expect(created.length).to eq(1)
        expect(returned).to all(equal(created.first))
        expect(created.first.save_calls).to eq(1)
      ensure
        2.times { release_init&.push(true) }
        threads&.each { |thread| thread.join(1) }
      end
    end

    it 'does not publish an ensured run until reconfiguration completes' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        reconfigure_started = Queue.new
        release_reconfigure = Queue.new
        results = Queue.new
        allow(ct).to receive(:reconfigure) do
          reconfigure_started << true
          release_reconfigure.pop
        end

        first_thread = Thread.new { results << ct.ensure_run_conf }
        reconfigure_started.pop
        second_thread = Thread.new { results << ct.ensure_run_conf }
        10_000.times do
          break if second_thread.status != 'run'

          Thread.pass
        end

        expect(second_thread.status).to eq('sleep')
        expect { results.pop(true) }.to raise_error(ThreadError)

        release_reconfigure << true
        expect(first_thread.join(1)).to be(first_thread)
        expect(second_thread.join(1)).to be(second_thread)

        returned = 2.times.map { results.pop }
        expect(returned).to all(equal(ct.run_conf))
        expect(ct.run_conf.save_calls).to eq(1)
      ensure
        release_reconfigure&.push(true) if first_thread&.alive?
        first_thread&.join(1)
        second_thread&.join(1)
      end
    end

    it 'moves the active run configuration to past_run_conf when stopped' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', active)

        expect(ct.stopped(active)).to be(true)

        expect(active.destroy_calls).to eq(1)
        expect(active.retirement_calls).to eq(1)
        expect(ct.run_conf).to be_nil
        expect(ct.get_past_run_conf).to eq(active)
      end
    end

    it 'keeps a retiring run attached until destroy completes' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        destroy_started = Queue.new
        release_destroy = Queue.new
        original_destroy = active.method(:destroy)
        active.define_singleton_method(:destroy) do
          destroy_started << true
          release_destroy.pop
          original_destroy.call
        end
        ct.instance_variable_set('@run_conf', active)
        allow(ct).to receive(:reconfigure)

        stop_thread = Thread.new { ct.stopped(active) }
        destroy_started.pop
        start_thread = Thread.new { ct.ensure_run_conf }
        read_result = Queue.new
        read_thread = Thread.new { read_result << ct.run_conf }

        expect(read_thread.join(1)).to be(read_thread)
        expect(read_result.pop).to be(active)
        expect(stop_thread).to be_alive
        expect(start_thread).to be_alive

        release_destroy << true
        expect(stop_thread.join(1)).to be(stop_thread)
        expect(stop_thread.value).to be(true)
        expect(start_thread.join(1)).to be(start_thread)
        expect(ct.run_conf).not_to be(active)
        expect(start_thread.value).to be(ct.run_conf)
        expect(ct.get_past_run_conf).to be(active)
      ensure
        release_destroy&.push(true) if stop_thread&.alive?
        read_thread&.join(1)
        stop_thread&.join(1)
        start_thread&.join(1)
      end
    end

    it 'elects one teardown owner while a concurrent same-run path waits' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        active = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', active)
        owner_entered = Queue.new
        waiter_entered = Queue.new
        release_owner = Queue.new
        effects_mutex = Mutex.new
        global_cleanup_calls = 0
        hook_calls = 0

        teardown = proc do
          ct.stopped(active) do |owner|
            unless owner
              waiter_entered << true
              next
            end

            effects_mutex.synchronize do
              global_cleanup_calls += 1
              hook_calls += 1
            end
            owner_entered << true
            Timeout.timeout(5) { release_owner.pop }
          end
        end

        owner_thread = Thread.new { teardown.call }
        Timeout.timeout(5) { owner_entered.pop }
        waiter_thread = Thread.new { teardown.call }
        Timeout.timeout(5) { waiter_entered.pop }

        expect(active.retirement_calls).to eq(2)
        expect(waiter_thread).to be_alive

        release_owner << true
        expect(owner_thread.join(5)).to be(owner_thread)
        expect(waiter_thread.join(5)).to be(waiter_thread)
        expect(owner_thread.value).to be(true)
        expect(waiter_thread.value).to be(true)
        expect(global_cleanup_calls).to eq(1)
        expect(hook_calls).to eq(1)
        expect(active.destroy_calls).to eq(1)
      ensure
        release_owner&.push(true) if owner_thread&.alive?
        owner_thread&.join(5)
        waiter_thread&.join(5)
      end
    end

    [
      [:post_stop, nil],
      [:recovery, nil],
      %i[post_stop bpf],
      %i[recovery bpf],
      %i[post_stop apparmor_destroy],
      %i[recovery apparmor_destroy]
    ].each do |teardown_owner, failure_step|
      description = if failure_step
                      "completes teardown after #{failure_step} fails with #{teardown_owner} as owner"
                    else
                      "serializes recovery and post-stop when #{teardown_owner} owns common teardown"
                    end

      it description do
        with_tmpdir do |dir|
          ct = build_container(root: dir)
          active = run_conf_class.new(ct, load_conf: false)
          ct.instance_variable_set('@run_conf', active)
          ct.state = :running
          allow(ct).to receive(:current_state).and_return(:stopped)

          effects = []
          effects_mutex = Mutex.new
          common_started = Queue.new
          injected_error = RuntimeError.new("#{failure_step} failed") if failure_step
          record_effect = lambda do |effect|
            path = Thread.current[:osctld_teardown_path]
            effects_mutex.synchronize { effects << [effect, path] }
            common_started << path if effect == :apparmor_destroy
          end

          netifs = ct.netifs
          netifs.define_singleton_method(:take_down) { nil }
          allow(netifs).to receive(:take_down) { record_effect.call(:netifs) }

          apparmor = ct.apparmor
          apparmor.define_singleton_method(:destroy_namespace) { nil }
          apparmor.define_singleton_method(:unload_profile) { nil }
          allow(apparmor).to receive(:destroy_namespace) do
            record_effect.call(:apparmor_destroy)
            raise injected_error if failure_step == :apparmor_destroy
          end
          allow(apparmor).to receive(:unload_profile) do
            record_effect.call(:apparmor_unload)
          end
          stub_const('OsCtld::AppArmor', Class.new do
            def self.enabled? = true
          end)

          stub_const('OsCtld::Hook', Class.new do
            def self.run(*); end
          end)
          stub_const('OsCtld::Eventd', Class.new do
            def self.report(*); end
          end)
          stub_const('OsCtld::DB::Containers', Class.new do
            class << self
              attr_accessor :container

              def find(*) = container
              def get = [container]
            end
          end)
          OsCtld::DB::Containers.container = ct
          allow(OsCtld::Hook).to receive(:run) do
            record_effect.call(:hook)
          end
          allow(OsCtld::Eventd).to receive(:report)
          allow(OsCtld::BpfFs).to receive(:remove_ct) do
            record_effect.call(:bpf)
            raise injected_error if failure_step == :bpf
          end

          user = instance_double(FakeObjects::FakeUser)
          peer = instance_double(OsCtld::ProcessIdentity)
          command = OsCtld::UserControl::Commands::CtPostStop.new(
            user,
            { id: ct.id, pool: ct.pool.name, run_id: 'active' },
            peer:
          )
          command.instance_variable_set(:@authenticated_run_conf, active)
          allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
          allow(command).to receive(:claim_lifecycle_event) do
            command.instance_variable_set(
              :@lifecycle_event_lease,
              active.acquire_lifecycle_lease
            )
            nil
          end
          allow(command).to receive(:log)
          allow(peer).to receive(:environment_variable).with('LXC_TARGET').and_return('stop')

          delayed_path = teardown_owner == :post_stop ? :recovery : :post_stop
          delayed_at_stop = Queue.new
          release_delayed = Queue.new
          owner_waiting = Queue.new
          allow(ct).to receive(:stopped).and_wrap_original do |original, *args, &block|
            if Thread.current[:osctld_teardown_path] == delayed_path
              delayed_at_stop << true
              Timeout.timeout(5) { release_delayed.pop }
            end
            original.call(*args, &block)
          end
          allow(active).to receive(:wait_for_lifecycle_leases).and_wrap_original do |original|
            owner_waiting << Thread.current[:osctld_teardown_path]
            original.call
          end

          recovery = OsCtld::Container::Recovery.new(ct)
          start_recovery = lambda do
            Thread.new do
              Thread.current.report_on_exception = false
              Thread.current[:osctld_teardown_path] = :recovery
              recovery.recover_state
            end
          end
          start_callback = lambda do
            Thread.new do
              Thread.current.report_on_exception = false
              Thread.current[:osctld_teardown_path] = :post_stop
              command.execute
            end
          end

          if delayed_path == :recovery
            recovery_thread = start_recovery.call
            Timeout.timeout(5) { delayed_at_stop.pop }
            callback_thread = start_callback.call
          else
            callback_thread = start_callback.call
            Timeout.timeout(5) { delayed_at_stop.pop }
            recovery_thread = start_recovery.call
          end

          expect(Timeout.timeout(5) { owner_waiting.pop }).to eq(teardown_owner)
          expect { common_started.pop(true) }.to raise_error(ThreadError)
          expect(effects_mutex.synchronize { effects.dup }).to eq(
            [[teardown_owner == :post_stop ? :bpf : :netifs, teardown_owner]]
          )

          release_delayed << true
          failed_path = failure_step == :bpf ? :post_stop : teardown_owner if failure_step
          failed_thread = failed_path == :post_stop ? callback_thread : recovery_thread
          successful_thread = failed_path == :post_stop ? recovery_thread : callback_thread

          if failure_step
            expect(successful_thread.join(5)).to be(successful_thread)
            expect { failed_thread.join(5) }.to raise_error do |error|
              expect(error).to be(injected_error)
            end
          else
            expect(callback_thread.join(5)).to be(callback_thread)
            expect(recovery_thread.join(5)).to be(recovery_thread)
          end

          unless failed_path == :post_stop
            expect(callback_thread.value).to eq(status: true, output: nil)
          end
          expect(recovery_thread.value).to be_nil unless failed_path == :recovery

          expected_effects = [
            [teardown_owner == :post_stop ? :bpf : :netifs, teardown_owner],
            [teardown_owner == :post_stop ? :netifs : :bpf, delayed_path],
            [:apparmor_destroy, teardown_owner],
            [:apparmor_unload, teardown_owner],
            [:hook, teardown_owner]
          ]
          expect(effects_mutex.synchronize { effects.dup }).to eq(expected_effects)
          expect(netifs).to have_received(:take_down).once
          expect(apparmor).to have_received(:destroy_namespace).once
          expect(apparmor).to have_received(:unload_profile).once
          expect(OsCtld::BpfFs).to have_received(:remove_ct).with(ct.pool.name, ct.id).once
          expect(OsCtld::Hook).to have_received(:run).with(ct, :post_stop).once
          expect(active.closed_lifecycle_lease_count).to eq(2)
          expect(active.destroy_observed_lease_count).to eq(0)
          expect(active.destroy_calls).to eq(1)
        ensure
          release_delayed&.push(true) if recovery_thread&.alive? || callback_thread&.alive?
          [recovery_thread, callback_thread].compact.each do |thread|
            thread.join(5)
          rescue StandardError
            # Expected injected failures are asserted above.
          end
        end
      end
    end

    it 'does not stop a replacement run' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        authenticated = run_conf_class.new(ct, load_conf: false)
        replacement = run_conf_class.new(ct, load_conf: false)
        ct.instance_variable_set('@run_conf', replacement)

        expect(ct.stopped(authenticated)).to be(false)
        expect(replacement.destroy_calls).to eq(0)
        expect(ct.run_conf).to be(replacement)
        expect(ct.get_past_run_conf).to be_nil
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

    it 'persists and reloads the recovery error state' do
      with_tmpdir do |dir|
        pool = build_container_pool(root: dir)
        ct = build_configured_container(root: dir, pool:)
        ct.state = :error
        ct.save_config
        cfg = load_yaml_file(ct.config_path)

        loaded = build_container(
          root: dir,
          pool:,
          load: true,
          devices: false
        )

        expect(cfg['state']).to eq('error')
        expect(loaded.state).to eq(:error)
        expect(loaded.can_start?).to be(false)
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

    it 'ignores an init pid which exits before its identity can be pinned' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        run_conf = ct.ensure_run_conf
        allow(run_conf).to receive(:init_pid=).and_raise(Errno::ESRCH)

        expect(ct.set_init_pid(4321)).to be_nil
        expect(ct.init_pid).to be_nil
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

    it 'does not install a refreshed PID into a replacement run' do
      with_tmpdir do |dir|
        ct = build_container(root: dir)
        old_run_conf = ct.ensure_run_conf
        ct.state = :running
        replacement = nil
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!) do
          expect(ct.stopped(old_run_conf)).to be(true)
          replacement = ct.ensure_run_conf
          ct.state = :running
          Struct.new(:state, :init_pid).new(:running, 5678)
        end

        expect(
          ct.refresh_init_pid(expected_run_conf: old_run_conf)
        ).to be_nil
        expect(ct.run_conf).to be(replacement)
        expect(replacement.init_pid).to be_nil
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
        expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :unset_dns_resolvers)
        expect(ct.lxc_config).to have_received(:configure_base).twice
      end
    end
  end
end
