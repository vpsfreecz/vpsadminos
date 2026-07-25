# frozen_string_literal: true

require 'osctld/container/run_id'

RSpec.describe OsCtld::Container::RunId do
  it 'uses the current timestamp and a random filesystem-safe key' do
    now = Time.at(1_717_171_717.125)
    allow(Time).to receive(:now).and_return(now)

    run_id = described_class.new(pool_name: 'tank', container_id: 'ct1')

    expect(run_id.timestamp).to eq(now.to_f)
    expect(run_id.key).to match(/\A[0-9a-f]{32}\z/)
    expect(run_id.to_s).to eq("tank:ct1:#{run_id.key}")
  end

  it 'round-trips through dump and load' do
    run_id = described_class.new(pool_name: 'tank', container_id: 'ct1', timestamp: 123.45)

    loaded = described_class.load(run_id.dump)

    expect(loaded.dump).to eq(run_id.dump)
  end

  it 'compares by value rather than object identity' do
    first = described_class.new(
      pool_name: 'tank',
      container_id: 'ct1',
      timestamp: 123.45,
      key: 'a' * 32
    )
    second = described_class.new(
      pool_name: 'tank',
      container_id: 'ct1',
      timestamp: 123.45,
      key: 'a' * 32
    )

    expect(first).to eq(second)
    expect(first).not_to equal(second)
  end

  it 'derives a stable key when loading a legacy timestamp-only id' do
    legacy = {
      'pool_name' => 'tank',
      'container_id' => 'ct1',
      'timestamp' => 123.45
    }

    first_key = described_class.load(legacy).key
    second_key = described_class.load(legacy).key

    expect(first_key).to eq(second_key)
  end

  it 'includes the run string in inspect' do
    run_id = described_class.new(pool_name: 'tank', container_id: 'ct1', timestamp: 123.45)

    expect(run_id.inspect).to include(run_id.to_s)
  end
end
