# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::HostLoad do
  def build_host_load(interval:, state_file:)
    stub_const('OsCtl::Oomd::HostLoad::STATE_FILE', state_file)
    described_class.new(interval)
  end

  it 'returns zero for an empty median' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))

      expect(host_load.median).to eq(0)
    end
  end

  it 'returns the middle sample for an odd-sized set' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))
      host_load.instance_variable_set(:@last_save, Time.now)

      [3, 1, 2].each { |value| host_load << value }

      expect(host_load.median).to eq(2)
    end
  end

  it 'returns the average of the middle samples for an even-sized set' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))
      host_load.instance_variable_set(:@last_save, Time.now)

      [4, 1, 2, 3].each { |value| host_load << value }

      expect(host_load.median).to eq(2.5)
    end
  end

  it 'sorts samples as they are appended' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))
      host_load.instance_variable_set(:@last_save, Time.now)

      [5, 1, 3].each { |value| host_load << value }

      expect(host_load.instance_variable_get(:@loads)).to eq([1, 3, 5])
    end
  end

  it 'trims history to one day worth of intervals' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))
      host_load.instance_variable_set(:@last_save, Time.now)
      allow(host_load).to receive(:save_state)

      1441.times { |i| host_load << i }

      expect(host_load.instance_variable_get(:@loads).length).to eq(1440)
      expect(host_load.instance_variable_get(:@loads).first).to eq(1)
    end
  end

  it 'initializes an empty list when the state file is missing' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'missing.yml'))

      expect(host_load.instance_variable_get(:@loads)).to eq([])
    end
  end

  it 'saves state through regenerate_file' do
    with_tmpdir do |dir|
      state_file = File.join(dir, 'host-load.yml')
      host_load = build_host_load(interval: 60, state_file:)
      allow(host_load).to receive(:regenerate_file).and_call_original

      host_load << 5

      expect(host_load).to have_received(:regenerate_file).with(state_file, 0o600)
      expect(File.read(state_file)).to include('loads')
      expect(File.read(state_file)).to include('- 5')
    end
  end

  it 'does not rewrite state more than once per minute' do
    with_tmpdir do |dir|
      host_load = build_host_load(interval: 60, state_file: File.join(dir, 'state.yml'))
      t0 = Time.at(100)

      host_load.instance_variable_set(:@last_save, t0)
      allow(host_load).to receive(:save_state)
      allow(Time).to receive(:now).and_return(t0 + 30)

      host_load << 5

      expect(host_load).not_to have_received(:save_state)
    end
  end
end
