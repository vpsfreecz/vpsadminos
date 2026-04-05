# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6/migrator/zfs'
require 'vpsadminos-converter/vz6/container'

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator::Zfs do
  let(:root_ds) { fake_dataset(name: 'tank/ct/101', relative_name: 'private') }
  let(:child_ds) { fake_dataset(name: 'tank/ct/101/data', relative_name: 'data') }
  let(:target_ct) do
    OpenStruct.new(
      id: '101',
      dataset: root_ds,
      datasets: [root_ds, child_ds]
    )
  end
  let(:vz_ct) { instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', running?: true) }
  let(:snapshots) { [] }
  let(:opts) do
    {
      dst: 'node.example',
      port: 2222,
      zfs_subdir: 'private',
      zfs_compressed_send: false
    }
  end
  let(:state) do
    instance_double(
      VpsAdminOS::Converter::Vz6::Migrator::State,
      vz_ct:,
      target_ct:,
      opts:,
      snapshots:,
      save: nil,
      set_step: nil,
      destroy: nil
    )
  end
  subject(:migrator) { described_class.new(state) }

  it 'rejects unsupported zfs_subdir during sync' do
    opts[:zfs_subdir] = 'root'

    expect { migrator.sync }.to raise_error(
      RuntimeError,
      'only zfs-subdir=private is implemented'
    )
  end

  it 'snapshots datasets, advances state, stores the snapshot, and sends all datasets during sync' do
    allow(Time).to receive(:now).and_return(Time.at(123))
    expect(migrator).to receive(:zfs).with(:snapshot, '-r', 'tank/ct/101@converter-migrate-base-123')
    expect(state).to receive(:set_step).with(:sync)
    expect(state).to receive(:save)
    expect(migrator).to receive(:send_dataset).with(target_ct, root_ds, 'converter-migrate-base-123')
    expect(migrator).to receive(:send_dataset).with(target_ct, child_ds, 'converter-migrate-base-123')

    migrator.sync

    expect(snapshots).to eq(['converter-migrate-base-123'])
  end

  it 'rejects unsupported zfs_subdir during transfer' do
    opts[:zfs_subdir] = 'root'

    expect { migrator.transfer }.to raise_error(
      RuntimeError,
      'only zfs-subdir=private is implemented'
    )
  end

  it 'stops, snapshots incrementally, sends incrementals, and transfers during transfer' do
    snapshots << 'converter-migrate-base-122'
    allow(Time).to receive(:now).and_return(Time.at(123))
    expect(migrator).to receive(:syscmd).with('vzctl stop 101')
    expect(migrator).to receive(:zfs).with(:snapshot, '-r', 'tank/ct/101@converter-migrate-incr-123')
    expect(state).to receive(:save)
    expect(migrator).to receive(:send_dataset_incr)
      .with(target_ct, root_ds, 'converter-migrate-incr-123', 'converter-migrate-base-122')
    expect(migrator).to receive(:send_dataset_incr)
      .with(target_ct, child_ds, 'converter-migrate-incr-123', 'converter-migrate-base-122')
    expect(migrator).to receive(:transfer_container).with(true)

    migrator.transfer

    expect(snapshots).to eq(
      %w[converter-migrate-base-122 converter-migrate-incr-123]
    )
  end

  it 'destroys snapshots and optionally removes the source container and dataset during cleanup' do
    snapshots.push('base', 'incr')
    expect(migrator).to receive(:zfs).with(:destroy, nil, 'tank/ct/101@base')
    expect(migrator).to receive(:zfs).with(:destroy, nil, 'tank/ct/101@incr')
    expect(migrator).to receive(:zfs).with(:destroy, nil, 'tank/ct/101/data@base')
    expect(migrator).to receive(:zfs).with(:destroy, nil, 'tank/ct/101/data@incr')
    expect(migrator).to receive(:syscmd).with('vzctl destroy 101')
    expect(migrator).to receive(:zfs).with(:destroy, '-r', root_ds)
    expect(state).to receive(:destroy)

    migrator.cleanup(delete: true)
  end

  it 'cancels remotely and destroys state' do
    expect(migrator).to receive(:cancel_remote).with(true)
    expect(state).to receive(:destroy)

    migrator.cancel(force: true)
  end

  it 'sends the base and last snapshot for datasets with multiple snapshots' do
    root_ds.snapshots = [fake_snapshot('snap1'), fake_snapshot('snap2')]
    expect(migrator).to receive(:progress).with(:step, 'Syncing private').ordered
    expect(migrator).to receive(:send_snapshot).with(target_ct, root_ds, 'base', 'snap1').ordered
    expect(migrator).to receive(:send_snapshot).with(target_ct, root_ds, 'base', 'snap2', 'snap1').ordered

    migrator.send(:send_dataset, target_ct, root_ds, 'base')
  end

  it 'sends incremental snapshots from the previous snapshot' do
    expect(migrator).to receive(:progress).with(:step, 'Syncing data').ordered
    expect(migrator).to receive(:send_snapshot)
      .with(target_ct, child_ds, 'incr', 'incr', 'base')
      .ordered

    migrator.send(:send_dataset_incr, target_ct, child_ds, 'incr', 'base')
  end

  it 'uses send_ssh_cmd for base snapshot receives and reports transfer progress' do
    stream = instance_double(OsCtl::Lib::Zfs::Stream, size: 1024)
    reader = instance_double(IO, close: nil)
    writer = instance_double(IO)
    status = instance_double(Process::Status, exitstatus: 0)

    allow(OsCtl::Lib::Zfs::Stream).to receive(:new).and_return(stream)
    allow(stream).to receive(:progress).and_yield(128, 128, 128)
    allow(stream).to receive(:spawn).and_return([reader, writer])
    allow(stream).to receive(:monitor)
    expect(migrator).to receive(:progress).with(:transfer, [1024, 128])
    expect(migrator).to receive(:send_ssh_cmd).with(
      nil,
      opts,
      %w[receive base 101 data snap1]
    ).and_return(['sh', '-c', 'cat >/dev/null'])
    expect(Process).to receive(:spawn).with('sh', '-c', 'cat >/dev/null', in: reader).and_return(123)
    expect(Process).to receive(:wait2).with(123).and_return([123, status])

    expect do
      migrator.send(:send_snapshot, target_ct, child_ds, 'snap1', 'snap1')
    end.not_to raise_error
  end

  it 'uses incremental receive mode without the base snapshot suffix when snapshots differ' do
    stream = instance_double(OsCtl::Lib::Zfs::Stream, size: 1024)
    reader = instance_double(IO, close: nil)
    writer = instance_double(IO)
    status = instance_double(Process::Status, exitstatus: 0)

    allow(OsCtl::Lib::Zfs::Stream).to receive(:new).and_return(stream)
    allow(stream).to receive(:progress)
    allow(stream).to receive(:spawn).and_return([reader, writer])
    allow(stream).to receive(:monitor)
    expect(migrator).to receive(:send_ssh_cmd).with(
      nil,
      opts,
      %w[receive incremental 101 data]
    ).and_return(['sh', '-c', 'cat >/dev/null'])
    allow(Process).to receive(:spawn).and_return(123)
    allow(Process).to receive(:wait2).with(123).and_return([123, status])

    migrator.send(:send_snapshot, target_ct, child_ds, 'base', 'incr', 'prev')
  end

  it 'raises when the remote receive exits unsuccessfully' do
    stream = instance_double(OsCtl::Lib::Zfs::Stream, size: 1024)
    reader = instance_double(IO, close: nil)
    writer = instance_double(IO)
    status = instance_double(Process::Status, exitstatus: 7)

    allow(OsCtl::Lib::Zfs::Stream).to receive(:new).and_return(stream)
    allow(stream).to receive(:progress)
    allow(stream).to receive(:spawn).and_return([reader, writer])
    allow(stream).to receive(:monitor)
    allow(migrator).to receive(:send_ssh_cmd).and_return(['sh', '-c', 'cat >/dev/null'])
    allow(Process).to receive(:spawn).and_return(123)
    allow(Process).to receive(:wait2).with(123).and_return([123, status])

    expect do
      migrator.send(:send_snapshot, target_ct, child_ds, 'snap1', 'snap1')
    end.to raise_error(RuntimeError, 'sync failed')
  end
end
