# frozen_string_literal: true

require 'osctld/eventd'

RSpec.describe OsCtld::Eventd do
  before do
    described_class.instance_variable_set(:@instance, nil)
  end

  after do
    described_class.instance_variable_set(:@instance, nil)
  end

  it 'delegates root methods to the singleton manager' do
    manager_class = stub_const('OsCtld::Eventd::Manager', Class.new)
    manager = instance_double(
      manager_class,
      start: nil,
      stop: nil,
      shutdown: nil,
      subscribe: nil,
      unsubscribe: nil,
      report: nil,
      broadcast: nil
    )

    allow(manager_class).to receive(:new).and_return(manager)

    described_class.start
    described_class.report(:state, id: 'ct1')
    described_class.broadcast(:state, id: 'ct1')
    described_class.stop

    expect(manager_class).to have_received(:new).once
    expect(manager).to have_received(:start).once
    expect(manager).to have_received(:report).with(:state, id: 'ct1')
    expect(manager).to have_received(:broadcast).with(:state, id: 'ct1')
    expect(manager).to have_received(:stop).once
  end
end
