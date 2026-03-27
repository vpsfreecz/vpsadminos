# frozen_string_literal: true

require 'osctld/eventd'
require 'osctld/eventd/event'
require 'osctld/eventd/manager'

RSpec.describe OsCtld::Eventd::Manager do
  def build_worker(size:)
    worker_class = Class.new do
      def start; end

      def stop; end

      def size; end

      def subscribe(_queue); end

      def unsubscribe(_queue); end

      def report(_event); end
    end

    instance_double(
      worker_class,
      start: nil,
      stop: nil,
      size:,
      subscribe: nil,
      unsubscribe: nil,
      report: nil
    )
  end

  it 'creates and starts the requested number of workers' do
    w1 = build_worker(size: 0)
    w2 = build_worker(size: 0)
    worker_class = Class.new

    stub_const('OsCtld::Eventd::Worker', worker_class)
    allow(worker_class).to receive(:new).and_return(w1, w2)

    manager = described_class.new
    manager.start(num_workers: 2)

    expect(worker_class).to have_received(:new).twice
    expect(w1).to have_received(:start)
    expect(w2).to have_received(:start)
  end

  it 'subscribes new queues on the least loaded worker' do
    w1 = build_worker(size: 3)
    w2 = build_worker(size: 1)
    worker_class = Class.new

    stub_const('OsCtld::Eventd::Worker', worker_class)
    allow(worker_class).to receive(:new).and_return(w1, w2)

    manager = described_class.new
    manager.start(num_workers: 2)
    queue = manager.subscribe

    expect(queue).to be_a(OsCtl::Lib::Queue)
    expect(w2).to have_received(:subscribe).with(queue)
  end

  it 'broadcasts events to all workers' do
    w1 = build_worker(size: 0)
    w2 = build_worker(size: 0)
    worker_class = Class.new
    reported = []

    allow(w1).to receive(:report) { |event| reported << [:w1, event] }
    allow(w2).to receive(:report) { |event| reported << [:w2, event] }

    stub_const('OsCtld::Eventd::Worker', worker_class)
    allow(worker_class).to receive(:new).and_return(w1, w2)

    manager = described_class.new
    manager.start(num_workers: 2)
    manager.report(:state, pool: 'tank', id: 'ct1')

    expect(reported.length).to eq(2)
    reported.each do |(_worker, event)|
      expect(event).to be_a(OsCtld::Eventd::Event)
      expect(event.type).to eq(:state)
      expect(event.opts).to eq(pool: 'tank', id: 'ct1')
    end
  end

  it 'asks every worker to unsubscribe queues' do
    w1 = build_worker(size: 0)
    w2 = build_worker(size: 0)
    worker_class = Class.new

    stub_const('OsCtld::Eventd::Worker', worker_class)
    allow(worker_class).to receive(:new).and_return(w1, w2)

    manager = described_class.new
    manager.start(num_workers: 2)
    queue = OsCtl::Lib::Queue.new

    manager.unsubscribe(queue)

    expect(w1).to have_received(:unsubscribe).with(queue)
    expect(w2).to have_received(:unsubscribe).with(queue)
  end

  it 'reports shutdown and then stops workers' do
    manager = described_class.new
    calls = []

    allow(manager).to receive(:report) { |type| calls << [:report, type] }
    allow(manager).to receive(:stop) { calls << [:stop] }

    manager.shutdown

    expect(calls).to eq([%i[report osctld_shutdown], [:stop]])
  end
end
