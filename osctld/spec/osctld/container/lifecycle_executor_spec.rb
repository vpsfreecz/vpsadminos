# frozen_string_literal: true

require 'timeout'
require 'osctld/container/lifecycle_executor'

RSpec.describe OsCtld::Container::LifecycleExecutor do
  let(:pool) do
    Struct.new(:name, :parallel_start, :parallel_stop)
          .new("tank-#{object_id}", 1, 1)
  end

  it 'bounds effects per pool and releases the lane explicitly' do
    expect(described_class.acquire(pool, :start, 'first')).to eq('first')
    acquired = Queue.new
    worker = Thread.new do
      acquired << described_class.acquire(pool, :start, 'second')
    end

    sleep(0.02)
    expect(acquired).to be_empty

    described_class.release(pool, :start, 'first')

    expect(Timeout.timeout(1) { acquired.pop }).to eq('second')
  ensure
    described_class.release(pool, :start, 'first')
    described_class.release(pool, :start, 'second')
    worker&.join
  end

  it 'uses independent start and stop lanes' do
    expect(described_class.acquire(pool, :start, 'start')).to eq('start')
    expect(described_class.acquire(pool, :stop, 'stop')).to eq('stop')
  ensure
    described_class.release(pool, :start, 'start')
    described_class.release(pool, :stop, 'stop')
  end
end
