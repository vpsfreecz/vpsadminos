# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6/migrator/ploop'

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator::Ploop do
  let(:vz_ct) do
    instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      ctid: '101',
      running?: true,
      status: { mounted: mounted }
    )
  end
  let(:target_ct) { OpenStruct.new(id: '101') }
  let(:opts) { { dst: 'node.example', port: 2222 } }
  let(:state) do
    instance_double(
      VpsAdminOS::Converter::Vz6::Migrator::State,
      vz_ct:,
      target_ct:,
      opts:,
      set_step: nil,
      save: nil
    )
  end
  let(:mounted) { false }
  subject(:migrator) { described_class.new(state) }

  it 'mounts only when needed during sync and unmounts afterwards' do
    expect(migrator).to receive(:syscmd).with('vzctl mount 101').ordered
    expect(migrator).to receive(:do_sync).ordered
    expect(state).to receive(:set_step).with(:sync).ordered
    expect(state).to receive(:save).ordered
    expect(migrator).to receive(:syscmd).with('vzctl umount 101').ordered

    migrator.sync
  end

  it 'does not mount or unmount during sync when already mounted' do
    allow(vz_ct).to receive(:status).and_return(mounted: true)
    expect(migrator).not_to receive(:syscmd).with('vzctl mount 101')
    expect(migrator).not_to receive(:syscmd).with('vzctl umount 101')
    allow(migrator).to receive(:do_sync)

    migrator.sync
  end

  it 'stops, mounts, syncs, transfers, and unmounts during transfer' do
    expect(migrator).to receive(:syscmd).with('vzctl stop 101').ordered
    expect(migrator).to receive(:syscmd).with('vzctl mount 101').ordered
    expect(migrator).to receive(:do_sync).ordered
    expect(migrator).to receive(:transfer_container).with(true).ordered
    expect(migrator).to receive(:syscmd).with('vzctl umount 101').ordered

    migrator.transfer
  end

  it 'still unmounts when sync fails after mounting' do
    expect(migrator).to receive(:syscmd).with('vzctl mount 101').ordered
    expect(migrator).to receive(:do_sync).and_raise('sync failure').ordered
    expect(migrator).to receive(:syscmd).with('vzctl umount 101').ordered

    expect { migrator.sync }.to raise_error(RuntimeError, 'sync failure')
  end
end
