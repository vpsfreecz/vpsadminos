require_relative '../spec_helper'
require_relative '../../image_pipeline/pool'

RSpec.describe ImagePipeline::Pool do
  it 'streams quick results while a long pipeline is active and reuses workers' do
    slow_started = Queue.new
    release_slow = Queue.new
    received = Queue.new
    workers = []
    factory = lambda do |index|
      worker = Object.new
      worker.define_singleton_method(:perform) do |item|
        if %w[gentoo guix].include?(item['name'])
          slow_started << true
          release_slow.pop
        end
        { 'status' => 'verified', 'builder' => 'fedora', 'worker' => index }
      end
      worker.define_singleton_method(:close) { nil }
      workers << worker
      worker
    end
    items = %w[quick-a gentoo guix quick-b].map { |name| { 'name' => name } }
    pool = described_class.new(items, workers: 2, factory:, result: ->(item, _) { received << item['name'] })
    thread = Thread.new { pool.run }
    slow_started.pop
    expect(received.pop).to eq('quick-a')
    expect(received.pop).to eq('quick-b')
    release_slow << true
    release_slow << true
    thread.value
    expect([received.pop, received.pop]).to contain_exactly('gentoo', 'guix')
    expect(workers.length).to eq(2)
  end

  it 'replaces a failed worker for one bounded retry while retaining assigned identity' do
    assignment = { 'config_digest' => 'frozen' }
    attempts = []
    outcomes = []
    factory = lambda do |index|
      worker = Object.new
      worker.define_singleton_method(:perform) do |item|
        attempts << item.fetch('attempt', 1)
        if index == 0
          item['assignment'] = assignment
          item['attempt'] = 1
          raise ImagePipeline::Worker::Failure, 'shell closed'
        end
        raise 'assignment changed' unless item['assignment'] == assignment

        { 'status' => 'verified' }
      end
      worker.define_singleton_method(:close) { nil }
      worker
    end
    described_class.new([{ 'name' => 'quick' }], workers: 1, factory:,
                                                 result: ->(_, result) { outcomes << result }).run
    expect(attempts).to eq([1, 2])
    expect(outcomes).to eq([{ 'status' => 'verified' }])
  end
end
