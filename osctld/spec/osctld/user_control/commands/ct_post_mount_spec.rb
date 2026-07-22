# frozen_string_literal: true

require 'osctld/dist_config'
require 'osctld/hook'
require 'osctld/process_identity'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_post_mount'

RSpec.describe OsCtld::UserControl::Commands::CtPostMount do
  before do
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(OsCtld::Hook).to receive(:run)
  end

  def build_context
    run_conf = Object.new
    ct = Struct.new(:map_mode).new('zfs')
    mount_ns = instance_double(File)
    root_stat = instance_double(File::Stat, directory?: true, dev: 1, ino: 10)
    root_dir = instance_double(File, stat: root_stat, closed?: false, close: nil)
    expected_root_dir = instance_double(
      File,
      stat: root_stat,
      close: nil
    )
    peer = instance_double(
      OsCtld::ProcessIdentity,
      pid: 123,
      namespace: mount_ns,
      release_root: nil
    )
    command = described_class.new(
      Object.new,
      { id: 'ct1', pool: 'tank', run_id: 'current', rootfs_dir: root_dir },
      peer:
    )

    allow(OsCtld::DB::Containers).to receive(:find)
      .with('ct1', 'tank')
      .and_return(ct)
    allow(command).to receive(:authenticate_lifecycle_callback)
      .with(ct)
      .and_return(nil)
    allow(command).to receive(:container_rootfs_mount)
      .with(ct)
      .and_return('/trusted/root')
    allow(File).to receive(:open)
      .with('/trusted/root', File::RDONLY | File::NOFOLLOW)
      .and_return(expected_root_dir)
    allow(command).to receive(:with_claimed_lifecycle_event)
      .with(ct, :post_mount, after: :pre_mount)
      .and_yield(run_conf)

    {
      command:,
      ct:,
      expected_root_dir:,
      mount_ns:,
      peer:,
      root_dir:,
      run_conf:
    }
  end

  it 'rejects a mounted rootfs descriptor for another directory' do
    context = build_context
    allow(OsCtld::DistConfig).to receive(:run)
    allow(context[:root_dir]).to receive(:stat).and_return(
      instance_double(File::Stat, directory?: true, dev: 2, ino: 20)
    )

    expect(context[:command].execute).to eq(
      status: false,
      message: 'invalid container rootfs or namespace: Invalid cross-device link - /trusted/root'
    )
    expect(OsCtld::DistConfig).not_to have_received(:run)
  end
end
