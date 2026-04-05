# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Spawn do
  let(:server) do
    instance_double(
      OsCtl::ExportFS::Server,
      name: 'srv',
      pid_file: '/run/osctl/exportfs/servers/srv/pid'
    )
  end
  let(:exports) { instance_double(OsCtl::ExportFS::Config::Exports) }
  let(:cfg) do
    instance_double(
      OsCtl::ExportFS::Config::TopLevel,
      address: '192.0.2.50',
      netif: 'nfs-srv',
      exports:
    )
  end
  let(:cgroup) { instance_double(OsCtl::ExportFS::Operations::Server::CGroup) }
  let(:sys) { build_fake_sys }

  before do
    allow(server).to receive(:synchronize).and_yield
    allow(server).to receive_messages(open_config: cfg, running?: false)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
    allow(OsCtl::ExportFS::Operations::Server::CGroup).to receive(:new).with(server).and_return(cgroup)
    allow(cgroup).to receive_messages(enter_manager: nil, clear_payload: nil, enter_payload: nil)
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
  end

  it 'keeps whitelisted mounts and unmounts the rest in reverse order' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      mounts = <<~MOUNTS
        devtmpfs /dev devtmpfs rw 0 0
        proc /proc proc rw 0 0
        tmpfs /zzz tmpfs rw 0 0
        tmpfs /aaa tmpfs rw 0 0
        tmpfs #{OsCtl::ExportFS::RunState::ROOTFS} tmpfs rw 0 0
        bind #{OsCtl::ExportFS::RunState::SERVERS}/srv/shared none rw 0 0
      MOUNTS
      allow(File).to receive(:open).with('/proc/mounts').and_return(StringIO.new(mounts))

      op = described_class.new('srv')
      op.send(:clear_mounts)

      expect(sys).to have_received(:unmount_lazy).with('/zzz').ordered
      expect(sys).to have_received(:unmount_lazy).with('/proc').ordered
      expect(sys).to have_received(:unmount_lazy).with('/aaa').ordered
    end
  end

  it 'bind-mounts each grouped export target once' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      allow(exports).to receive(:group_by_as).and_return(
        [
          ['/srv/data', 'exports/data', %i[first second]],
          ['/srv/logs', 'exports/logs', [:third]]
        ]
      )

      op = described_class.new('srv')
      op.send(:add_exports)

      expect(sys).to have_received(:bind_mount).with('/srv/data', File.join(OsCtl::ExportFS::RunState::ROOTFS, 'exports/data'))
      expect(sys).to have_received(:bind_mount).with('/srv/logs', File.join(OsCtl::ExportFS::RunState::ROOTFS, 'exports/logs'))
    end
  end

  it 'cleans up after a successful child run' do
    allow(Process).to receive(:fork).and_return(123)
    allow(Process).to receive(:wait2).with(123).and_return([123, build_wait_status(0)])
    allow(Signal).to receive(:trap)
    allow(FileUtils).to receive(:rm_f)

    op = described_class.new('srv')
    allow(op).to receive(:syscmd)
    allow(op).to receive(:log)
    op.execute

    expect(cgroup).to have_received(:enter_manager)
    expect(FileUtils).to have_received(:rm_f).with('/run/osctl/exportfs/servers/srv/pid')
    expect(op).to have_received(:syscmd).with('ip link del nfs-srv')
    expect(cgroup).to have_received(:clear_payload)
  end

  it 'propagates a failed child exit status and tolerates a missing pid file' do
    allow(Process).to receive(:fork).and_return(123)
    allow(Process).to receive(:wait2).with(123).and_return([123, build_wait_status(5)])
    allow(Signal).to receive(:trap)
    allow(FileUtils).to receive(:rm_f)

    op = described_class.new('srv')
    allow(op).to receive(:syscmd)
    allow(op).to receive(:log)

    expect { op.execute }.to raise_error(RuntimeError, 'server spawn failed with exit status 5')
    expect(FileUtils).to have_received(:rm_f).with('/run/osctl/exportfs/servers/srv/pid')
    expect(op).to have_received(:syscmd).with('ip link del nfs-srv')
    expect(cgroup).to have_received(:clear_payload)
  end
end
