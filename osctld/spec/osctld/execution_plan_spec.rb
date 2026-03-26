# frozen_string_literal: true

require 'osctld/execution_plan'

RSpec.describe OsCtld::ExecutionPlan do
  subject(:plan) { described_class.new }

  it 'enqueues items before start and reports queue state' do
    plan << 1
    plan << 2

    expect(plan.queue).to eq([1, 2])
    expect(plan.length).to eq(2)
    expect(plan.empty?).to be(false)
    expect(plan.running?).to be(false)
  end

  it 'raises when enqueueing after run starts' do
    gate = Queue.new

    plan << 1
    plan.run(threads: 1) { pop_with_timeout(gate) }

    expect { plan << 2 }.to raise_error(RuntimeError, 'already in progress')

    gate << true
    plan.wait
  end

  it 'calls on_start and on_done once and processes all queued items' do
    lifecycle = Queue.new
    processed = Queue.new

    3.times { |i| plan << i }
    plan.on_start { lifecycle << :start }
    plan.on_done { lifecycle << :done }

    plan.run(threads: 2) { |item| processed << item }
    plan.wait

    expect(pop_with_timeout(lifecycle)).to eq(:start)
    expect(pop_with_timeout(lifecycle)).to eq(:done)
    expect([pop_with_timeout(processed), pop_with_timeout(processed), pop_with_timeout(processed)]).to contain_exactly(0, 1, 2)
  end

  it 'waits until execution completes' do
    gate = Queue.new
    events = Queue.new

    plan << 1
    plan.run(threads: 1) { pop_with_timeout(gate) }

    waiter = Thread.new do
      events << :waiting
      plan.wait
      events << :done
    end

    expect(pop_with_timeout(events)).to eq(:waiting)
    expect { events.pop(true) }.to raise_error(ThreadError)

    gate << true

    expect(pop_with_timeout(events)).to eq(:done)
    waiter.join
  end

  it 'stops by clearing queued work while letting the running item finish' do
    started = Queue.new
    release = Queue.new
    processed = Queue.new
    stopped = Queue.new

    [1, 2, 3].each { |item| plan << item }

    plan.run(threads: 1) do |item|
      started << item
      pop_with_timeout(release) if item == 1
      processed << item
    end

    expect(pop_with_timeout(started)).to eq(1)

    stopper = Thread.new do
      plan.stop
      stopped << true
    end

    expect { stopped.pop(true) }.to raise_error(ThreadError)

    release << true

    expect(pop_with_timeout(processed)).to eq(1)
    expect(pop_with_timeout(stopped)).to be(true)
    expect(plan.queue).to be_empty
    expect(plan.running?).to be(false)
    expect { processed.pop(true) }.to raise_error(ThreadError)

    stopper.join
  end

  it 'selects all and half thread counts from nprocessors' do
    allow(Etc).to receive(:nprocessors).and_return(8)

    expect(plan.default_threads).to eq(4)
    expect(plan.send(:get_threads, :all)).to eq(8)
    expect(plan.send(:get_threads, :half)).to eq(4)
  end
end
