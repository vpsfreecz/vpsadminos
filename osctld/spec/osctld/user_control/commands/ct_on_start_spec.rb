# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
# rubocop:disable RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_on_start'

RSpec.describe OsCtld::UserControl::Commands::CtOnStart do
  subject(:command) { described_class.new(user, opts) }

  let(:user) { instance_double('User') }
  let(:run_conf) { instance_double('RunConfig') }
  let(:ct_cgroup_path) { '/osctl/pool.tank/group.default/user.alice/ct.ct1/user-owned' }
  let(:monitor_cgroup_path) { File.join(ct_cgroup_path, 'lxc.monitor.ct1') }
  let(:payload_cgroup_path) { File.join(ct_cgroup_path, 'lxc.payload.ct1') }
  let(:ct) do
    instance_double(
      'Container',
      id: 'ct1',
      user:,
      run_conf:,
      root_host_gid: 100_000,
      cgroup_path: ct_cgroup_path,
      entry_cgroup_path: monitor_cgroup_path,
      payload_cgroup_path:
    )
  end
  let(:opts) { { id: 'ct1', pool: 'tank' } }

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double(find: ct))
    stub_const(
      'OsCtld::DistConfig',
      Module.new do
        def self.run(*); end
      end
    )

    stub_const(
      'OsCtld::CGroup',
      Module.new do
        def self.v2?
          false
        end

        def self.abs_cgroup_path(_subsystem, path)
          File.join('/run/osctl/cgroup', path)
        end

        def self.fs
          '/run/osctl/cgroup'
        end

        def self.chown_delegated(_cgroup, uid:, gid:); end

        def self.delegate_available_controllers(_cgroup); end

        def self.get_cgroup_pids(_subsystem, _path)
          []
        end

        def self.attach_to(_subsystem, _path, pid:); end
      end
    )

    stub_const(
      'OsCtld::Hook',
      Module.new do
        def self.run(*); end
      end
    )

    allow(OsCtld::DistConfig).to receive(:run)
    allow(OsCtld::CGroup).to receive(:chown_delegated)
    allow(OsCtld::CGroup).to receive(:delegate_available_controllers) do |_cgroup, &prepare|
      prepare&.call
    end
    allow(OsCtld::CGroup).to receive(:get_cgroup_pids).and_return([])
    allow(OsCtld::CGroup).to receive(:attach_to)
    allow(OsCtld::Hook).to receive(:run)
    allow(user).to receive(:ugid).and_return(1000)
    allow(command).to receive(:log)
  end

  it 'configures the guest and runs the trusted legacy callback without an init or run identity' do
    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :start)
    expect(OsCtld::Hook).to have_received(:run).with(ct, :on_start)
  end

  it 'rejects a callback from a different container user before delegation' do
    allow(ct).to receive(:user).and_return(instance_double('User'))

    expect(command.execute).to eq(status: false, message: 'access denied')
    expect(OsCtld::CGroup).not_to have_received(:chown_delegated)
    expect(OsCtld::DistConfig).not_to have_received(:run)
    expect(OsCtld::Hook).not_to have_received(:run)
  end

  it 'delegates cgroup v2 controllers on the container cgroup namespace root' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)

    root_cgroup = File.join('/run/osctl/cgroup', ct_cgroup_path)
    payload_cgroup = File.join('/run/osctl/cgroup', payload_cgroup_path)
    ancestor_cgroups = %w[
      /run/osctl/cgroup/osctl
      /run/osctl/cgroup/osctl/pool.tank
      /run/osctl/cgroup/osctl/pool.tank/group.default
      /run/osctl/cgroup/osctl/pool.tank/group.default/user.alice
      /run/osctl/cgroup/osctl/pool.tank/group.default/user.alice/ct.ct1
    ]

    ancestor_cgroups.each do |cgroup|
      expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).with(cgroup)
    end

    expect(OsCtld::CGroup).to have_received(:chown_delegated).with(
      root_cgroup,
      uid: 1000,
      gid: 100_000
    )
    expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).once.with(root_cgroup)
    expect(OsCtld::CGroup).to have_received(:chown_delegated).with(
      payload_cgroup,
      uid: 1000,
      gid: 100_000
    )
  end

  it 'does not migrate unidentified host processes by numeric pid' do
    stub_const("#{described_class}::CGROUP_DELEGATE_BUSY_RETRIES", 1)
    allow(OsCtld::CGroup).to receive_messages(v2?: true, get_cgroup_pids: [2349])
    allow(command).to receive(:sleep)

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(command).to have_received(:sleep).once.with(
      described_class::CGROUP_DELEGATE_BUSY_RETRY_DELAY
    )
    expect(command).to have_received(:log).with(
      :warn,
      ct,
      /unexpected processes remain in the container cgroup: 2349/
    )
    expect(OsCtld::CGroup).not_to have_received(:attach_to)
  end

  it 'does not require an empty namespace root when controller delegation is a no-op' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(command).to receive(:sleep)
    root_cgroup = File.join('/run/osctl/cgroup', ct_cgroup_path)

    allow(OsCtld::CGroup).to receive(:delegate_available_controllers) do |cgroup, &prepare|
      prepare&.call unless cgroup == root_cgroup
    end

    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).not_to have_received(:get_cgroup_pids)
    expect(command).not_to have_received(:sleep)
    expect(command).not_to have_received(:log)
  end

  it 'retries delegation until LXC finishes placing its monitor' do
    remaining = [[2349], []]
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(OsCtld::CGroup).to receive(:get_cgroup_pids) do
      remaining.shift || []
    end
    allow(command).to receive(:sleep)

    expect(command.execute).to eq(status: true, output: nil)
    expect(command).to have_received(:sleep).once.with(
      described_class::CGROUP_DELEGATE_BUSY_RETRY_DELAY
    )
    expect(OsCtld::CGroup).not_to have_received(:attach_to)
  end

  it 'keeps v2 start hooks working when the payload cgroup is not visible yet' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(OsCtld::CGroup).to receive(:chown_delegated) do |cgroup, **|
      raise Errno::ENOENT if cgroup == File.join('/run/osctl/cgroup', payload_cgroup_path)
    end

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).with(
      File.join('/run/osctl/cgroup', ct_cgroup_path)
    )
  end

  it 'retries v2 controller delegation when the cgroup namespace root is busy' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(command).to receive(:sleep)

    root_cgroup = File.join('/run/osctl/cgroup', ct_cgroup_path)
    root_attempts = 0

    allow(OsCtld::CGroup).to receive(:delegate_available_controllers) do |cgroup|
      next unless cgroup == root_cgroup

      root_attempts += 1
      raise Errno::EBUSY if root_attempts < 3
    end

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).exactly(3).times.with(
      root_cgroup
    )
    expect(command).to have_received(:sleep).twice.with(
      described_class::CGROUP_DELEGATE_BUSY_RETRY_DELAY
    )
  end

  it 'retries v2 controller delegation when the cgroup namespace root is not ready' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(command).to receive(:sleep)

    root_cgroup = File.join('/run/osctl/cgroup', ct_cgroup_path)
    root_attempts = 0

    allow(OsCtld::CGroup).to receive(:delegate_available_controllers) do |cgroup|
      next unless cgroup == root_cgroup

      root_attempts += 1
      raise Errno::EOPNOTSUPP if root_attempts < 3
    end

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).exactly(3).times.with(
      root_cgroup
    )
    expect(command).to have_received(:sleep).twice.with(
      described_class::CGROUP_DELEGATE_BUSY_RETRY_DELAY
    )
  end

  it 'keeps v2 start hooks working when controller delegation remains busy' do
    allow(OsCtld::CGroup).to receive(:v2?).and_return(true)
    allow(command).to receive(:sleep)
    allow(command).to receive(:log)
    root_cgroup = File.join('/run/osctl/cgroup', ct_cgroup_path)

    allow(OsCtld::CGroup).to receive(:delegate_available_controllers) do |cgroup|
      raise Errno::EBUSY if cgroup == root_cgroup
    end

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :start)
    expect(OsCtld::CGroup).to have_received(:delegate_available_controllers).exactly(
      described_class::CGROUP_DELEGATE_BUSY_RETRIES + 1
    ).times.with(root_cgroup)
    expect(command).to have_received(:sleep).exactly(
      described_class::CGROUP_DELEGATE_BUSY_RETRIES
    ).times.with(described_class::CGROUP_DELEGATE_BUSY_RETRY_DELAY)
    expect(command).to have_received(:log).with(
      :warn,
      ct,
      /Unable to delegate cgroup v2 controllers.*after #{described_class::CGROUP_DELEGATE_BUSY_RETRIES} retries/
    )
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
# rubocop:enable RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles
