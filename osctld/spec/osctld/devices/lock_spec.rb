# frozen_string_literal: true

require 'osctld/devices/change_set'
require 'osctld/devices/lock'

RSpec.describe OsCtld::Devices::Lock do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }

  before do
    described_class.instance.instance_variable_set('@pools', {})
  end

  it 'reuses a mutex per pool' do
    mutex_a = described_class.instance.send(:mutex, pool)
    mutex_b = described_class.instance.send(:mutex, pool)

    expect(mutex_a).to equal(mutex_b)
  end

  it 'opens and closes a changeset only once for nested sync blocks' do
    allow(OsCtld::Devices::ChangeSet).to receive(:open)
    allow(OsCtld::Devices::ChangeSet).to receive(:close)

    described_class.sync(pool) do
      described_class.sync(pool) { :nested }
    end

    expect(OsCtld::Devices::ChangeSet).to have_received(:open).once.with(pool)
    expect(OsCtld::Devices::ChangeSet).to have_received(:close).once.with(pool)
  end
end
