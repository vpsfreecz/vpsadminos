# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/queue'

RSpec.describe OsCtl::Lib::Queue do
  it 'pushes, prepends, and exposes queue contents' do
    queue = described_class.new

    queue.push(1)
    queue << 2
    queue.insert(0)

    expect(queue.to_a).to eq([0, 1, 2])
    expect(queue.length).to eq(3)
    expect(queue).not_to be_empty
    expect(queue).to be_any
  end

  it 'supports blocking and nonblocking shifts and timeouts' do
    queue = described_class.new
    results = ::Queue.new

    thread = Thread.new do
      results << queue.shift
    end

    queue.push(:value)

    expect(results.pop).to eq(:value)
    expect(queue.shift(block: false)).to be_nil
    expect(queue.shift(timeout: 0.05)).to be_nil

    thread.join
  end

  it 'continues waiting after spurious wakeups' do
    queue = described_class.new

    thread = Thread.new do
      queue.shift(timeout: 0.5)
    end

    sleep(0.05)

    queue.instance_variable_get(:@mutex).synchronize do
      queue.instance_variable_get(:@cond).signal
    end

    sleep(0.05)
    queue.push(:value)

    expect(thread.value).to eq(:value)
  end

  it 'returns nil for expired timeouts' do
    queue = described_class.new

    expect(queue.shift(timeout: 0)).to be_nil
    expect(queue.shift(timeout: -1)).to be_nil
  end

  it 'clears the queue' do
    queue = described_class.new
    queue.push(1)
    queue.push(2)

    queue.clear

    expect(queue).to be_empty
    expect(queue.length).to eq(0)
  end
end
