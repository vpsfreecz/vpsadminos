# frozen_string_literal: true

require 'osctld/lockable'
require 'osctld/eventd/event'
require 'osctld/eventd/worker'

RSpec.describe OsCtld::Eventd::Worker do
  subject(:worker) { described_class.new }

  after do
    worker.stop
  end

  it 'tracks subscriber count' do
    q1 = OsCtl::Lib::Queue.new
    q2 = OsCtl::Lib::Queue.new

    worker.subscribe(q1)
    worker.subscribe(q2)
    expect(worker.size).to eq(2)

    worker.unsubscribe(q1)
    expect(worker.size).to eq(1)
  end

  it 'delivers reported events to all subscribers' do
    q1 = OsCtl::Lib::Queue.new
    q2 = OsCtl::Lib::Queue.new
    event = OsCtld::Eventd::Event.new(:state, pool: 'tank', id: 'ct1')

    worker.subscribe(q1)
    worker.subscribe(q2)
    worker.start

    worker.report(event)

    expect(pop_with_timeout(q1)).to eq(event)
    expect(pop_with_timeout(q2)).to eq(event)
  end

  it 'clears subscribers on stop' do
    worker.subscribe(OsCtl::Lib::Queue.new)
    worker.start

    worker.stop

    expect(worker.size).to eq(0)
  end
end
