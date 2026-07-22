# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles

require 'securerandom'
require 'osctld/container/run_configuration'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/base'

RSpec.describe OsCtld::UserControl::Commands::Base do
  let(:handle) { :"spec_user_control_base_#{SecureRandom.hex(4)}" }
  let(:command_class) do
    current_handle = handle

    Class.new(described_class) do
      handle current_handle

      def execute
        ok
      end
    end
  end
  let(:user) { Object.new }
  let(:command) { command_class.new(user, {}) }

  it 'registers commands through UserControl::Command' do
    command_class

    expect(OsCtld::UserControl::Command.find(handle)).to be(command_class)
  end

  it 'recognizes containers owned by the calling user' do
    ct_class = Struct.new(:user, keyword_init: true)

    expect(command.send(:owns_ct?, ct_class.new(user: user))).to be(true)
    expect(command.send(:owns_ct?, ct_class.new(user: Object.new))).to be(false)
  end

  it 'derives the native rootfs target before its idmapped bind exists' do
    rootfs_mount = "/run/osctl/spec-rootfs-#{SecureRandom.hex(8)}"
    shared_dir = instance_double(
      'OsCtld::Mount::SharedDir',
      host_path_for: rootfs_mount
    )
    run_conf = instance_double(
      'OsCtld::Container::RunConfiguration',
      rootfs: '/tank/ct/private'
    )
    ct = double(
      'OsCtld::Container',
      map_mode: 'native',
      mounts: double('OsCtld::Mount::Manager', shared_dir:)
    )

    command.instance_variable_set(:@authenticated_run_conf, run_conf)

    expect(File.exist?(rootfs_mount)).to be(false)
    expect(command.send(:container_rootfs_mount, ct)).to eq(rootfs_mount)
    expect(shared_dir).to have_received(:host_path_for).with('/tank/ct/private')
  end

  it 'binds callbacks to the peer cgroup and current run' do
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      alive?: true,
      in_cgroup_subtree?: true
    )
    run_id = instance_double('OsCtld::Container::RunId', to_s: 'tank:ct1:1')
    run_conf = instance_double('OsCtld::Container::RunConfiguration', run_id:)
    ct = double(
      'Container',
      user:,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1',
      run_conf:
    )
    allow(ct).to receive(:inclusively).and_yield
    authenticated = command_class.new(
      user,
      { run_id: 'tank:ct1:1' },
      peer:
    )

    expect(authenticated.send(:authenticate_run_callback, ct)).to be_nil
    expect(peer).to have_received(:in_cgroup_subtree?).with('/osctl/pool.tank/ct.ct1')
  end

  it 'rejects stale run identifiers before lifecycle work' do
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      alive?: true,
      in_cgroup_subtree?: true
    )
    run_conf = instance_double(
      'OsCtld::Container::RunConfiguration',
      run_id: instance_double('OsCtld::Container::RunId', to_s: 'current')
    )
    ct = double(
      'Container',
      user:,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1',
      run_conf:
    )
    stale = command_class.new(user, { run_id: 'old' }, peer:)

    expect(stale.send(:authenticate_run_callback, ct)).to eq(
      status: false,
      message: 'stale container run'
    )
  end

  it 'claims an ordered event only at the command lifecycle depth' do
    lifecycle = instance_double('OsCtld::ProcessIdentity')
    lease = instance_double(
      OsCtld::Container::RunConfiguration::LifecycleLease,
      close: nil
    )
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      alive?: true,
      in_cgroup_subtree?: true,
      descendant_at_depth?: true
    )
    run_conf = instance_double(
      'OsCtld::Container::RunConfiguration',
      run_id: instance_double('OsCtld::Container::RunId', to_s: 'current'),
      lifecycle_identity: lifecycle,
      acquire_lifecycle_lease: lease,
      claim_lifecycle_event: true
    )
    ct = double(
      'Container',
      user:,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1',
      run_conf:
    )
    allow(ct).to receive(:inclusively).and_yield
    authenticated = command_class.new(user, { run_id: 'current' }, peer:)

    expect(
      authenticated.send(:authenticate_lifecycle_callback, ct)
    ).to be_nil
    expect(peer).to have_received(:descendant_at_depth?).with(lifecycle, 1)

    expect(
      authenticated.send(
        :with_claimed_lifecycle_event,
        ct,
        :pre_mount,
        after: :pre_start
      ) do |leased_run|
        expect(leased_run).to be(run_conf)
        expect(lease).not_to have_received(:close)
        :effect_complete
      end
    ).to eq(:effect_complete)
    expect(run_conf).to have_received(:claim_lifecycle_event).with(
      :pre_mount,
      after: :pre_start
    )
    expect(lease).to have_received(:close).once
  end

  it 'never moves an authenticated callback onto a replacement run ledger' do
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      alive?: true,
      in_cgroup_subtree?: true
    )
    old_run = instance_double(
      'OsCtld::Container::RunConfiguration',
      run_id: instance_double('OsCtld::Container::RunId', to_s: 'current')
    )
    new_run = instance_double(
      'OsCtld::Container::RunConfiguration',
      run_id: instance_double('OsCtld::Container::RunId', to_s: 'current')
    )
    ct = double(
      'Container',
      user:,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1'
    )
    allow(ct).to receive(:run_conf).and_return(old_run, new_run)
    allow(ct).to receive(:inclusively).and_yield
    authenticated = command_class.new(user, { run_id: 'current' }, peer:)
    allow(old_run).to receive(:claim_lifecycle_event)
    allow(new_run).to receive(:claim_lifecycle_event)

    expect(authenticated.send(:authenticate_run_callback, ct)).to be_nil
    expect(
      authenticated.send(:claim_lifecycle_event, ct, :pre_mount, after: :pre_start)
    ).to eq(status: false, message: 'stale container run')
    expect(old_run).not_to have_received(:claim_lifecycle_event)
    expect(new_run).not_to have_received(:claim_lifecycle_event)
  end

  it 'rejects a deeper lifecycle descendant before claiming an event' do
    lifecycle = instance_double('OsCtld::ProcessIdentity')
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      alive?: true,
      in_cgroup_subtree?: true,
      descendant_at_depth?: false
    )
    run_conf = instance_double(
      'OsCtld::Container::RunConfiguration',
      run_id: instance_double('OsCtld::Container::RunId', to_s: 'current'),
      lifecycle_identity: lifecycle
    )
    ct = double(
      'Container',
      user:,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1',
      run_conf:
    )
    authenticated = command_class.new(user, { run_id: 'current' }, peer:)
    allow(run_conf).to receive(:claim_lifecycle_event)

    expect(authenticated.send(:authenticate_lifecycle_callback, ct)).to eq(
      status: false,
      message: 'callback does not belong to the active container lifecycle'
    )
    expect(run_conf).not_to have_received(:claim_lifecycle_event)
  end
end

# rubocop:enable RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles
