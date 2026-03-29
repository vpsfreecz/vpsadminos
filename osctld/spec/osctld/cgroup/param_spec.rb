# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/cgroup/param'

RSpec.describe OsCtld::CGroup::Param do
  around do |example|
    version = OsCtld::CGroup.method(:version)

    example.run
  ensure
    OsCtld::CGroup.define_singleton_method(:version, version)
  end

  before do
    OsCtld::CGroup.define_singleton_method(:version) { 2 }
  end

  it 'loads and imports params with persistent flags' do
    loaded = described_class.load(
      'version' => 1,
      'subsystem' => 'cpu',
      'name' => 'cpu.cfs_quota_us',
      'value' => [100_000]
    )
    imported = described_class.import(
      subsystem: 'memory',
      parameter: 'memory.max',
      value: [200_000],
      version: 2,
      persistent: false
    )

    expect(loaded.dump).to eq(
      'version' => 1,
      'subsystem' => 'cpu',
      'name' => 'cpu.cfs_quota_us',
      'value' => [100_000],
      'persistent' => true
    )
    expect(imported.export).to eq(
      version: 2,
      subsystem: 'memory',
      parameter: 'memory.max',
      value: [200_000],
      persistent: false
    )
  end
end
