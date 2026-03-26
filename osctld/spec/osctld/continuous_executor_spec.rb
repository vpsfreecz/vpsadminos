# frozen_string_literal: true

require 'osctld/continuous_executor'

RSpec.describe OsCtld::ContinuousExecutor do
  subject(:executor) { executor_class.new(1) }

  let(:executor_class) do
    Class.new(described_class) do
      def log(*); end

      def denixstorify(*)
        ['trace']
      end

      def puts(*); end
    end
  end

  def build_command(id: nil, priority: 10, &block)
    described_class::Command.new(id:, priority:, &block)
  end

  after do
    executor.stop
  end

  it 'supports enqueue and <<' do
    processed = Queue.new

    executor.enqueue(build_command(id: 'first') { |cmd| processed << cmd.id })
    executor << build_command(id: 'second') { |cmd| processed << cmd.id }
    executor.wait_until_empty

    expect(pop_with_timeout(processed)).to eq('first')
    expect(pop_with_timeout(processed)).to eq('second')
  end

  it 'returns the callable result from execute' do
    result = executor.execute(build_command(id: 'result') { 42 })

    expect(result).to eq(42)
  end

  it 'runs lower numeric priorities first' do
    order = Queue.new
    release = Queue.new

    executor.enqueue(build_command(id: 'blocker', priority: 0) do
      order << :blocker_started
      pop_with_timeout(release)
    end)
    expect(pop_with_timeout(order)).to eq(:blocker_started)

    executor.enqueue(build_command(id: 'low', priority: 5) { order << :low })
    executor.enqueue(build_command(id: 'high', priority: 1) { order << :high })

    release << true
    executor.wait_until_empty

    expect(pop_with_timeout(order)).to eq(:high)
    expect(pop_with_timeout(order)).to eq(:low)
  end

  it 'preserves fifo order among equal priorities' do
    order = Queue.new
    release = Queue.new

    executor.enqueue(build_command(id: 'blocker', priority: 0) do
      order << :blocker_started
      pop_with_timeout(release)
    end)
    expect(pop_with_timeout(order)).to eq(:blocker_started)

    executor.enqueue(build_command(id: 'first', priority: 5) { order << :first })
    executor.enqueue(build_command(id: 'second', priority: 5) { order << :second })

    release << true
    executor.wait_until_empty

    expect(pop_with_timeout(order)).to eq(:first)
    expect(pop_with_timeout(order)).to eq(:second)
  end

  it 'removes queued commands by id before they start' do
    order = Queue.new
    release = Queue.new

    executor.enqueue(build_command(id: 'blocker') do
      order << :blocker_started
      pop_with_timeout(release)
    end)
    expect(pop_with_timeout(order)).to eq(:blocker_started)

    executor.enqueue(build_command(id: 'remove-me') { order << :removed })
    executor.enqueue(build_command(id: 'keep-me') { order << :kept })
    executor.remove('remove-me')

    release << true
    executor.wait_until_empty

    expect(pop_with_timeout(order)).to eq(:kept)
    expect { order.pop(true) }.to raise_error(ThreadError)
  end

  it 'clears queued but not running commands' do
    order = Queue.new
    release = Queue.new

    executor.enqueue(build_command(id: 'blocker') do
      order << :blocker_started
      pop_with_timeout(release)
    end)
    expect(pop_with_timeout(order)).to eq(:blocker_started)

    executor.enqueue(build_command(id: 'first') { order << :first })
    executor.enqueue(build_command(id: 'second') { order << :second })
    executor.clear

    Timeout.timeout(2) do
      Thread.pass until executor.queue.empty?
    end

    release << true
    executor.wait_until_empty

    expect { order.pop(true) }.to raise_error(ThreadError)
  end

  it 'waits until the queue is empty' do
    events = Queue.new
    release = Queue.new

    executor.enqueue(build_command(id: 'blocker') do
      events << :running
      pop_with_timeout(release)
    end)
    expect(pop_with_timeout(events)).to eq(:running)

    waiter = Thread.new do
      events << :waiting
      executor.wait_until_empty
      events << :done
    end

    expect(pop_with_timeout(events)).to eq(:waiting)
    expect { events.pop(true) }.to raise_error(ThreadError)

    release << true

    expect(pop_with_timeout(events)).to eq(:done)
    waiter.join
  end

  it 'starts queued commands when resized upward' do
    started = Queue.new
    release_one = Queue.new
    release_two = Queue.new

    executor.enqueue(build_command(id: 'one') do
      started << :one
      pop_with_timeout(release_one)
    end)
    expect(pop_with_timeout(started)).to eq(:one)

    executor.enqueue(build_command(id: 'two') do
      started << :two
      pop_with_timeout(release_two)
    end)

    executor.resize(2)

    expect(pop_with_timeout(started)).to eq(:two)

    release_one << true
    release_two << true
    executor.wait_until_empty
  end

  it 'continues processing after command exceptions' do
    processed = Queue.new

    executor.enqueue(build_command(id: 'boom') { raise 'boom' })
    executor.enqueue(build_command(id: 'after') { processed << :after })
    executor.wait_until_empty

    expect(pop_with_timeout(processed)).to eq(:after)
  end
end
