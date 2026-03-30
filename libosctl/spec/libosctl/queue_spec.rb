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

  it 'clears the queue' do
    queue = described_class.new
    queue.push(1)
    queue.push(2)

    queue.clear

    expect(queue).to be_empty
    expect(queue.length).to eq(0)
  end
end
