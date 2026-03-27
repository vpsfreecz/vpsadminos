# frozen_string_literal: true

require 'osctld/system_limits'
require 'osctld/prlimits/prlimit'
require 'osctld/prlimits/manager'

RSpec.describe OsCtld::PrLimits::Manager do
  let(:ct) do
    FakeObjects::FakeRuntimeContainer.new(
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      lxc_config: FakeObjects::FakeLxcConfig.new
    )
  end

  before do
    allow(OsCtld::SystemLimits).to receive(:ensure_nofile)
  end

  it 'loads managers from hash and legacy array formats' do
    hash_loaded = described_class.load(ct, { 'nofile' => { 'soft' => 1024, 'hard' => 2048 } })
    array_loaded = described_class.load(ct, [{ 'name' => 'nproc', 'soft' => 10, 'hard' => 20 }])

    expect(hash_loaded['nofile'].hard).to eq(2048)
    expect(array_loaded['nproc'].soft).to eq(10)
  end

  it 'builds default limits' do
    manager = described_class.default(ct)

    expect(manager['nofile'].soft).to eq(1024)
    expect(manager['nofile'].hard).to eq(OsCtld::SystemLimits::FILE_MAX_DEFAULT)
  end

  it 'sets, updates, and exports limits while persisting configuration' do
    manager = described_class.new(ct)

    manager.set('nofile', 1024, 2048)
    manager.set('cpu', 10, 20)
    manager.set('nofile', 4096, 8192)

    expect(manager['nofile'].hard).to eq(8192)
    expect(manager.contains?('cpu')).to be(true)
    expect(manager.export).to eq(
      'nofile' => { soft: 4096, hard: 8192 },
      'cpu' => { soft: 10, hard: 20 }
    )
    expect(ct.save_config_calls).to eq(3)
    expect(ct.lxc_config.prlimit_calls).to eq(3)
    expect(OsCtld::SystemLimits).to have_received(:ensure_nofile).with(2048)
    expect(OsCtld::SystemLimits).to have_received(:ensure_nofile).with(8192)
  end

  it 'unsets limits and iterates over entries' do
    manager = described_class.new(
      ct,
      entries: {
        'nofile' => OsCtld::PrLimits::PrLimit.new('nofile', 1024, 2048),
        'nproc' => OsCtld::PrLimits::PrLimit.new('nproc', 10, 20)
      }
    )

    yielded = manager.each.map { |name, limit| [name, limit.hard] }
    manager.unset('nproc')

    expect(yielded).to contain_exactly(['nofile', 2048], ['nproc', 20])
    expect(manager.contains?('nproc')).to be(false)
    expect(manager.dump).to eq('nofile' => { 'soft' => 1024, 'hard' => 2048 })
  end

  it 'duplicates managers into independent hash-backed stores' do
    manager = described_class.new(
      ct,
      entries: {
        'nofile' => OsCtld::PrLimits::PrLimit.new('nofile', 1024, 2048)
      }
    )
    other_ct = FakeObjects::FakeRuntimeContainer.new(pool: ct.pool, id: 'ct2', lxc_config: FakeObjects::FakeLxcConfig.new)

    copy = manager.dup(other_ct)
    copy.set('nofile', 4096, 8192)

    expect(copy['nofile'].hard).to eq(8192)
    expect(manager['nofile'].hard).to eq(2048)
  end
end
