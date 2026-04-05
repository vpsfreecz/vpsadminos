# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6/migrator/base'

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator::Base do
  let(:target_ct) { Struct.new(:id).new('101') }
  let(:opts) { { dst: 'node.example', port: nil } }
  let(:state) do
    instance_double(
      VpsAdminOS::Converter::Vz6::Migrator::State,
      target_ct:,
      opts:,
      save: nil,
      set_step: nil
    )
  end
  subject(:migrator) { described_class.new(state) }

  it 'stages the skeleton, defaults ssh port to 22, and saves state' do
    with_tmpdir do |dir|
      output = File.join(dir, 'skel.dat')

      allow(migrator).to receive(:export_skel) { |_ct, io| io.write('skeleton-data') }
      expect(migrator).to receive(:send_ssh_cmd)
        .with(nil, opts, %w[receive skel])
        .and_return(['sh', '-c', "'cat >#{output}'"])
      expect(state).to receive(:save)

      migrator.stage

      expect(opts[:port]).to eq(22)
      expect(File.read(output)).to eq('skeleton-data')
    end
  end

  it 'raises when staging exits with a non-zero status' do
    allow(migrator).to receive(:export_skel) { |_ct, io| io.write('payload') }
    allow(migrator).to receive(:send_ssh_cmd).and_return(['sh', '-c', "'exit 7'"])

    expect { migrator.stage }.to raise_error(RuntimeError, 'stage failed')
  end

  it 'transfers the container, reports progress, advances the state, and saves it' do
    events = []
    migrator.send(:progress_handler=, proc { |type, value| events << [type, value] })

    expect(migrator).to receive(:send_ssh_cmd)
      .with(nil, opts, %w[receive transfer 101 start])
      .and_return(['sh', '-c', 'exit 0'])
    expect(state).to receive(:set_step).with(:transfer)
    expect(state).to receive(:save)

    migrator.send(:transfer_container, true)

    expect(events).to eq([[:step, 'Starting on the target node']])
  end

  it 'raises when transfer exits with a non-zero status' do
    allow(migrator).to receive(:send_ssh_cmd).and_return(['sh', '-c', 'exit 7'])

    expect { migrator.send(:transfer_container, false) }.to raise_error(
      RuntimeError,
      'transfer failed'
    )
  end

  it 'allows remote cancellation to fail when nofail is true' do
    allow(migrator).to receive(:send_ssh_cmd).and_return(['sh', '-c', 'exit 7'])

    expect { migrator.send(:cancel_remote, true) }.not_to raise_error
  end

  it 'raises when remote cancellation fails without nofail' do
    allow(migrator).to receive(:send_ssh_cmd).and_return(['sh', '-c', 'exit 7'])

    expect { migrator.send(:cancel_remote, false) }.to raise_error(RuntimeError, 'cancel failed')
  end

  it 'calls the progress handler when present and no-ops otherwise' do
    events = []
    migrator.send(:progress_handler=, proc { |type, value| events << [type, value] })

    migrator.send(:progress, :step, 'syncing')
    migrator.send(:progress_handler=, nil)

    expect { migrator.send(:progress, :step, 'ignored') }.not_to raise_error
    expect(events).to eq([[:step, 'syncing']])
  end
end
