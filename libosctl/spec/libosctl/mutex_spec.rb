# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/mutex'

RSpec.describe OsCtl::Lib::Mutex do
  it 'locks, unlocks, and reports ownership' do
    mutex = described_class.new

    mutex.lock
    expect(mutex).to be_locked
    expect(mutex).to be_owned

    mutex.unlock

    expect(mutex).not_to be_locked
    expect(mutex).not_to be_owned
  end

  it 'synchronizes a block and releases the lock afterwards' do
    mutex = described_class.new
    value = mutex.synchronize do
      expect(mutex).to be_owned
      42
    end

    expect(value).to eq(42)
    expect(mutex).not_to be_locked
  end

  it 'times out when another thread holds the lock' do
    mutex = described_class.new
    mutex.lock

    result = ::Queue.new

    thread = Thread.new do
      mutex.lock(0.1)
      result << :locked
    rescue described_class::Timeout
      result << :timeout
    end

    expect(result.pop).to eq(:timeout)

    mutex.unlock
    thread.join
  end

  it 'releases the lock during sleep and reacquires it afterwards' do
    mutex = described_class.new
    mutex.lock

    events = ::Queue.new

    thread = Thread.new do
      events << :waiting
      mutex.lock
      events << :acquired
      mutex.unlock
    end

    expect(events.pop).to eq(:waiting)

    mutex.sleep(0.05, 0.5)

    expect(events.pop).to eq(:acquired)
    expect(mutex).to be_owned

    mutex.unlock
    thread.join
  end

  it 'raises when a different thread unlocks the mutex' do
    mutex = described_class.new
    mutex.lock

    errors = ::Queue.new

    thread = Thread.new do
      mutex.unlock
    rescue ThreadError => e
      errors << e
    end

    error = errors.pop

    expect(error).to be_a(ThreadError)
    expect(error.message).to include('another thread')

    mutex.unlock
    thread.join
  end
end
