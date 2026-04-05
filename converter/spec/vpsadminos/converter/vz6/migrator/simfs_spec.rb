# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6/migrator/simfs'

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator::Simfs do
  let(:vz_ct) { instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', running?: running) }
  let(:target_ct) { OpenStruct.new(id: '101', rootfs: '/vz/private/101') }
  let(:opts) { { dst: 'node.example', port: 2222 } }
  let(:state) do
    instance_double(
      VpsAdminOS::Converter::Vz6::Migrator::State,
      vz_ct:,
      target_ct:,
      opts:,
      set_step: nil,
      save: nil,
      destroy: nil
    )
  end
  let(:running) { true }
  subject(:migrator) { described_class.new(state) }

  it 'syncs the container, advances to sync, and saves state' do
    expect(migrator).to receive(:do_sync)
    expect(state).to receive(:set_step).with(:sync)
    expect(state).to receive(:save)

    migrator.sync
  end

  it 'stops, syncs again, and transfers with start when the container had been running' do
    expect(migrator).to receive(:syscmd).with('vzctl stop 101')
    expect(migrator).to receive(:do_sync)
    expect(migrator).to receive(:transfer_container).with(true)

    migrator.transfer
  end

  it 'passes a false start flag when the container was not running' do
    allow(vz_ct).to receive(:running?).and_return(false)
    expect(migrator).to receive(:syscmd).with('vzctl stop 101')
    expect(migrator).to receive(:do_sync)
    expect(migrator).to receive(:transfer_container).with(false)

    migrator.transfer
  end

  it 'optionally destroys the source container during cleanup and always destroys state' do
    expect(migrator).to receive(:syscmd).with('vzctl destroy 101')
    expect(state).to receive(:destroy)

    migrator.cleanup(delete: true)
  end

  it 'cancels remotely with force and destroys state' do
    expect(migrator).to receive(:cancel_remote).with(true)
    expect(state).to receive(:destroy)

    migrator.cancel(force: true)
  end

  it 'parses the destination rootfs from osctl json output' do
    expect(migrator).to receive(:root_sshcmd).with('osctl -j ct show 101').and_return(
      command_result('{"rootfs":"/ct/rootfs"}')
    )

    expect(migrator.send(:dst_rootfs)).to eq('/ct/rootfs')
  end

  it 'builds the expected rsync command' do
    expect(migrator).to receive(:syscmd) do |command, options|
      expect(command).to eq(
        'rsync -rlptgoDHX --numeric-ids --inplace --delete-after --exclude .zfs/ ' \
        '-e "ssh -p 2222" /src/ node.example:/dst/'
      )
      expect(options).to eq(valid_rcs: [23, 24])
    end

    migrator.send(:rsync, '/src/', '/dst/', valid_rcs: [23, 24])
  end

  it 'builds the expected root ssh command' do
    expect(migrator).to receive(:syscmd).with(
      'ssh -o StrictHostKeyChecking=no -T -p 2222 -l root node.example osctl -j ct show 101'
    ).and_return(command_result('{}'))

    migrator.send(:root_sshcmd, 'osctl -j ct show 101')
  end
end
