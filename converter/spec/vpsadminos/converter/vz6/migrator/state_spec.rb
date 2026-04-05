# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6/migrator/state'

StateSpecVzCt = Struct.new(:ctid, :ploop?)
StateSpecTargetCt = Struct.new(:id, :dataset)

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator::State do
  let(:vz_ct) { StateSpecVzCt.new('101', false) }
  let(:target_ct) { StateSpecTargetCt.new('101', 'tank/ct/101') }
  let(:opts) { { dst: 'node.example', zfs: false } }
  let(:data) do
    {
      step: :stage,
      vz_ct:,
      target_ct:,
      opts:,
      snapshots: []
    }
  end

  it 'creates a new migration state' do
    state = described_class.create(vz_ct, target_ct, opts)

    expect(state.ctid).to eq('101')
    expect(state.step).to eq(:stage)
    expect(state.vz_ct).to eq(vz_ct)
    expect(state.target_ct).to eq(target_ct)
    expect(state.opts).to eq(opts)
    expect(state.snapshots).to eq([])
  end

  it 'loads a valid Marshal payload' do
    with_tmpdir do |dir|
      allow(described_class).to receive(:state_dir).and_return(dir)

      File.open(described_class.state_file('101'), 'wb') do |f|
        Marshal.dump(data, f)
      end

      state = described_class.load('101')

      expect(state.ctid).to eq('101')
      expect(state.step).to eq(:stage)
      expect(state.target_ct).to eq(target_ct)
    end
  end

  it 'rejects non-hash state payloads' do
    with_tmpdir do |dir|
      allow(described_class).to receive(:state_dir).and_return(dir)

      File.open(described_class.state_file('101'), 'wb') do |f|
        Marshal.dump('invalid', f)
      end

      expect { described_class.load('101') }.to raise_error(RuntimeError, 'invalid state format')
    end
  end

  it 'allows only the expected state transitions' do
    state = described_class.new('101', data)

    expect(state.can_proceed?(:sync)).to be(true)
    expect(state.can_proceed?(:cancel)).to be(true)
    expect(state.can_proceed?(:stage)).to be(false)
    expect(state.can_proceed?(:cleanup)).to be(false)

    state.set_step(:sync)

    expect(state.can_proceed?(:transfer)).to be(true)
    expect(state.can_proceed?(:cancel)).to be(true)
    expect(state.can_proceed?(:stage)).to be(false)
    expect(state.can_proceed?(:sync)).to be(false)
    expect(state.can_proceed?(:cleanup)).to be(false)

    state.set_step(:transfer)

    expect(state.can_proceed?(:cleanup)).to be(true)
    expect(state.can_proceed?(:cancel)).to be(false)
    expect(state.can_proceed?(:sync)).to be(false)
  end

  it 'updates the current step only for valid transitions' do
    state = described_class.new('101', data)

    state.set_step(:sync)
    expect(state.step).to eq(:sync)

    expect { state.set_step(:stage) }.to raise_error(RuntimeError, 'invalid migration sequence')
  end

  it 'saves and reloads state from disk' do
    with_tmpdir do |dir|
      allow(described_class).to receive(:state_dir).and_return(dir)

      state = described_class.new('101', data.merge(step: :sync, snapshots: ['base']))
      state.save

      loaded = described_class.load('101')

      expect(loaded.step).to eq(:sync)
      expect(loaded.snapshots).to eq(['base'])
      expect(loaded.opts).to eq(opts)
    end
  end

  it 'destroys the persisted state file' do
    with_tmpdir do |dir|
      allow(described_class).to receive(:state_dir).and_return(dir)

      state = described_class.new('101', data)
      state.save
      state.destroy

      expect(File.exist?(described_class.state_file('101'))).to be(false)
    end
  end

  it 'can save in a clean ruby process' do
    with_tmpdir do |dir|
      script = <<~RUBY
        VzCt = Struct.new(:ctid, :ploop?)
        TargetCt = Struct.new(:id)

        module VpsAdminOS
          module Converter
            module Vz6; end
          end
        end

        require 'vpsadminos-converter/vz6/migrator'
        require 'vpsadminos-converter/vz6/migrator/state'

        class << VpsAdminOS::Converter::Vz6::Migrator::State
          def state_dir
            #{dir.inspect}
          end
        end

        state = VpsAdminOS::Converter::Vz6::Migrator::State.new('101', {
          step: :stage,
          vz_ct: VzCt.new('101', false),
          target_ct: TargetCt.new('101'),
          opts: {},
          snapshots: []
        })

        state.save
      RUBY

      _stdout, stderr, status = run_isolated_ruby(script)

      expect(status.success?).to be(true), stderr
    end
  end
end
