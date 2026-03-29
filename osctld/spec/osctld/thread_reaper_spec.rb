# frozen_string_literal: true

require 'timeout'
require 'osctld/thread_reaper'

RSpec.describe OsCtld::ThreadReaper do
  subject(:reaper) { fresh_singleton(described_class) }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  after do
    reaper.stop
  rescue StandardError
    nil
  end

  def wait_until(timeout: 2)
    Timeout.timeout(timeout) do
      sleep(0.01) until yield
    end
  rescue Timeout::Error
    raise "condition not met after #{timeout}s"
  end

  it 'adds threads and managers through the work queue' do
    alive = true
    thread = instance_double(Thread)

    allow(thread).to receive(:alive?) { alive }
    allow(thread).to receive(:join).with(0.05) { alive ? nil : true }

    reaper.start
    reaper.add(thread, :manager)

    wait_until { reaper.export == [[thread, :manager]] }

    alive = false
    wait_until { reaper.export.empty? }

    expect(reaper.export).to be_empty
  end

  it 'returns a cloned export instead of the live thread array' do
    thread = instance_double(Thread)
    reaper.instance_variable_set(:@threads, [[thread, :manager]])

    exported = reaper.export
    exported.clear

    expect(reaper.export).to eq([[thread, :manager]])
  end

  it 'joins and removes dead threads' do
    dead = instance_double(Thread, alive?: false)
    alive = instance_double(Thread, alive?: true)

    allow(dead).to receive(:join).with(0.05).and_return(true)

    reaper.instance_variable_set(:@threads, [[dead, nil], [alive, nil]])

    reaper.send(:join_dead_threads)

    expect(reaper.export).to eq([[alive, nil]])
  end

  it 'requests stop from living managers and waits until threads can be reaped' do
    alive = true
    thread = instance_double(Thread, backtrace: ['/nix/store/x', '/tmp/y'])
    manager = Struct.new do
      def request_stop; end
    end.new

    allow(thread).to receive(:alive?) { alive }
    allow(thread).to receive(:join).with(0.05) { alive ? nil : true }
    allow(manager).to receive(:request_stop) { alive = false }

    reaper.start
    reaper.add(thread, manager)
    wait_until { reaper.export == [[thread, manager]] }

    reaper.stop

    expect(manager).to have_received(:request_stop)
    expect(reaper.export).to be_empty
  end

  it 'raises on unknown queue commands' do
    reaper.instance_variable_get(:@queue) << :bogus

    expect do
      reaper.send(:run)
    end.to raise_error(RuntimeError, /unknown command 'bogus'/)
  end
end
