# frozen_string_literal: true

require 'osctld/auto_start/config'

AutoStartConfigSpecContainer = Struct.new(:id, keyword_init: true)

RSpec.describe OsCtld::AutoStart::Config do
  let(:ct) { instance_double(AutoStartConfigSpecContainer, id: 'ct2') }

  it 'loads priority and delay from config' do
    config = described_class.load(ct, 'priority' => 10, 'delay' => 30)

    expect(config.ct).to eq(ct)
    expect(config.priority).to eq(10)
    expect(config.delay).to eq(30)
  end

  it 'sorts by priority and container id' do
    lower_priority = described_class.new(instance_double(AutoStartConfigSpecContainer, id: 'ct3'), 5, 0)
    first = described_class.new(instance_double(AutoStartConfigSpecContainer, id: 'ct1'), 10, 0)
    second = described_class.new(instance_double(AutoStartConfigSpecContainer, id: 'ct2'), 10, 0)

    expect([second, lower_priority, first].sort).to eq([lower_priority, first, second])
  end

  it 'dumps the persisted fields' do
    config = described_class.new(ct, 12, 45)

    expect(config.dump).to eq(
      'priority' => 12,
      'delay' => 45
    )
  end

  it 'rebinds the container on dup' do
    replacement = instance_double(AutoStartConfigSpecContainer, id: 'ct9')
    original = described_class.new(ct, 7, 3)

    copy = original.dup(replacement)

    expect(copy.ct).to eq(replacement)
    expect(copy.priority).to eq(7)
    expect(copy.delay).to eq(3)
  end
end
