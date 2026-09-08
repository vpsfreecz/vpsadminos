# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/hook'
require 'osctld/container/hooks'

RSpec.describe OsCtld::Container::Hooks do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:user) { FakeObjects::FakeUser.new(name: 'alice', userdir: '/userdir') }
  let(:group) { FakeObjects::FakeGroup.new(name: '/default') }
  let(:hostname) { double(to_s: 'ct1.example') }
  let(:run_conf) do
    double(
      dataset: 'tank/ct/ct1',
      rootfs: '/rootfs',
      distribution: 'alpine',
      version: '3.20'
    )
  end
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      user: user,
      group: group,
      get_run_conf: run_conf,
      map_mode: 'zfs',
      lxc_home: '/var/lib/lxc',
      lxc_dir: '/var/lib/lxc/ct1',
      cgroup_path: '/osctl/tank/ct.ct1',
      hostname: hostname,
      log_path: '/var/log/ct1.log'
    )
  end

  it 'registers container hook classes under the expected names' do
    expect(OsCtld::Hook.exist?(OsCtld::Container, :pre_start)).to be(true)
    expect(OsCtld::Hook.exist?(OsCtld::Container, :post_stop)).to be(true)
  end

  it 'builds environment variables for container hooks' do
    hook = described_class::PostStart.new(ct, init_pid: 123)

    expect(hook.send(:environment)).to include(
      'OSCTL_POOL_NAME' => 'tank',
      'OSCTL_CT_ID' => 'ct1',
      'OSCTL_CT_USER' => 'alice',
      'OSCTL_CT_GROUP' => '/default',
      'OSCTL_CT_INIT_PID' => '123'
    )
  end

  it 'uses nsenter for mount hooks' do
    mnt_ns = instance_double(IO, fileno: 42)
    hook = described_class::PreMount.new(
      ct,
      rootfs_mount: '/mnt/rootfs',
      ns_pid: 321,
      mnt_ns:
    )

    expect(hook.send(:environment)).to include(
      'OSCTL_CT_ROOTFS_MOUNT' => '/mnt/rootfs',
      'OSCTL_CT_NS_PID' => '321'
    )
    expect(hook.send(:executable, '/hook/path')).to eq(
      ['nsenter', '--mount=/proc/self/fd/42', '/hook/path']
    )
    expect(hook.send(:inherited_files)).to eq([mnt_ns])
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
