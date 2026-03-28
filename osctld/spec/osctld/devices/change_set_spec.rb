# frozen_string_literal: true

require 'osctld/devices/change_set'

RSpec.describe OsCtld::Devices::ChangeSet do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }

  before do
    described_class.instance.instance_variable_set('@pools', {})
  end

  it 'opens a per-pool changeset and stores managers by sort key' do
    manager = double

    described_class.open(pool)
    described_class.add(pool, manager, 'b')

    expect(described_class.instance.instance_variable_get('@pools')).to eq(
      'tank' => { 'b' => manager }
    )
  end

  it 'closes a changeset in sorted order' do
    events = []
    first = double
    second = double
    allow(first).to receive(:apply) { events << :first }
    allow(second).to receive(:apply) { events << :second }

    described_class.open(pool)
    described_class.add(pool, second, 'b')
    described_class.add(pool, first, 'a')

    described_class.close(pool)

    expect(events).to eq(%i[first second])
  end
end
