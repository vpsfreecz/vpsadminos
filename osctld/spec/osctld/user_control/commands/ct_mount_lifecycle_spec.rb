# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubleReference

require 'osctld/user_control/commands/ct_post_mount'
require 'osctld/user_control/commands/ct_pre_mount'
require 'osctld/user_control/commands/ct_autodev'
require 'osctld/dist_config'

RSpec.describe 'authenticated container mount callbacks' do
  let(:user) { instance_double('User') }
  let(:opts) { { id: 'ct1', pool: 'tank', run_id: 'current' } }

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double)
    stub_const(
      'OsCtld::Hook',
      Class.new do
        def self.run(*); end
      end
    )
  end

  it 'limits cloned-child setup hooks to exact lifecycle grandchildren' do
    command_classes = [
      OsCtld::UserControl::Commands::CtPreMount,
      OsCtld::UserControl::Commands::CtPostMount,
      OsCtld::UserControl::Commands::CtAutodev
    ]

    command_classes.each do |command_class|
      command = command_class.new(user, opts, peer: instance_double('OsCtld::ProcessIdentity'))

      expect(command.send(:lifecycle_peer_depth)).to eq(2)
    end
  end

  it 'derives the rootfs and mount namespace before claiming pre-mount' do
    mnt_ns = instance_double(IO)
    peer = instance_double('OsCtld::ProcessIdentity', pid: 4321)
    run_conf = instance_double('RunConfig')
    ct = instance_double('Container', map_mode: 'zfs', run_conf:)
    command = OsCtld::UserControl::Commands::CtPreMount.new(
      user,
      opts.merge(rootfs_mount: '/attacker/root'),
      peer:
    )

    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    allow(peer).to receive(:namespace).with(:mnt).and_return(mnt_ns)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:container_rootfs_mount).with(ct).and_return('/trusted/root')
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, :pre_mount, after: :pre_start)
      .and_return(nil)
    allow(OsCtld::Hook).to receive(:run)

    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::Hook).to have_received(:run).with(
      ct,
      :pre_mount,
      rootfs_mount: '/trusted/root',
      ns_pid: 4321,
      mnt_ns:
    )
  end

  it 'accepts only the mounted rootfs descriptor sent by the authenticated hook' do
    root_stat = instance_double(File::Stat, directory?: true, dev: 1, ino: 10)
    root_dir = instance_double(File, stat: root_stat, closed?: false, close: nil)
    expected_root_dir = instance_double(
      File,
      stat: root_stat,
      close: nil
    )
    peer = instance_double(
      'OsCtld::ProcessIdentity'
    )
    ct = instance_double('Container', map_mode: 'zfs', run_conf: instance_double('RunConfig'))
    command = OsCtld::UserControl::Commands::CtPostMount.new(
      user,
      opts.merge(rootfs_dir: root_dir),
      peer:
    )
    claim_rejection = { status: false, message: 'claimed for test' }

    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:container_rootfs_mount).with(ct).and_return('/trusted/root')
    allow(File).to receive(:open)
      .with('/trusted/root', File::RDONLY | File::NOFOLLOW)
      .and_return(expected_root_dir)
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, :post_mount, after: :pre_mount)
      .and_return(claim_rejection)

    expect(command.execute).to eq(claim_rejection)
    expect(root_dir).to have_received(:close)
    expect(expected_root_dir).to have_received(:close)
  end

  it 'releases post-mount rootfs descriptors before cleaning the native target' do
    events = []
    root_stat = instance_double(File::Stat, directory?: true, dev: 1, ino: 10)
    root_dir = instance_double(File, stat: root_stat, closed?: false)
    expected_root_dir = instance_double(
      File,
      stat: root_stat
    )
    mnt_ns = instance_double(File)
    peer = instance_double(
      'OsCtld::ProcessIdentity',
      pid: 4321,
      namespace: mnt_ns
    )
    run_conf = instance_double('RunConfig', rootfs: '/source/root')
    shared_dir_class = Class.new do
      def cleanup_pushed(_rootfs); end
    end
    mounts_class = Class.new do
      attr_reader :shared_dir

      def initialize(shared_dir)
        @shared_dir = shared_dir
      end

      def each; end
    end
    shared_dir = instance_double(shared_dir_class)
    mounts = instance_double(mounts_class, shared_dir:)
    ct = instance_double(
      Struct.new(:map_mode, :run_conf, :mounts),
      map_mode: 'native',
      run_conf:,
      mounts:
    )
    command = OsCtld::UserControl::Commands::CtPostMount.new(
      user,
      opts.merge(rootfs_dir: root_dir),
      peer:
    )

    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:container_rootfs_mount).with(ct).and_return('/trusted/root')
    allow(File).to receive(:open)
      .with('/trusted/root', File::RDONLY | File::NOFOLLOW)
      .and_return(expected_root_dir)
    allow(command).to receive(:with_claimed_lifecycle_event)
      .with(ct, :post_mount, after: :pre_mount)
      .and_yield(run_conf)
    allow(mounts).to receive(:each)
    allow(root_dir).to receive(:close) { events << :close_root }
    allow(expected_root_dir).to receive(:close) { events << :close_expected }
    allow(peer).to receive(:release_root) { events << :release_peer_root }
    allow(shared_dir).to receive(:cleanup_pushed) do |rootfs|
      events << [:cleanup, rootfs]
    end
    allow(OsCtld::DistConfig).to receive(:run_with_status) do
      events << :dist_config
      [true, nil]
    end
    allow(OsCtld::Hook).to receive(:run) { events << :hook }

    expect(command.execute).to eq(status: true, output: nil)
    expect(events).to eq(
      [
        :dist_config,
        :hook,
        :close_root,
        :close_expected,
        :release_peer_root,
        [:cleanup, '/source/root']
      ]
    )
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubleReference
