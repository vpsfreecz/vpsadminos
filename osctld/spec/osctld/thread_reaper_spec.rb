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

  it 'forwards keyword arguments through class helpers' do
    instance = instance_double(described_class)

    allow(described_class).to receive(:instance).and_return(instance)
    allow(instance).to receive(:add)
    allow(instance).to receive(:drain)

    described_class.add(:thread, :manager, group: :management)
    described_class.drain(group: :management)

    expect(instance).to have_received(:add).with(
      :thread,
      :manager,
      group: :management
    )
    expect(instance).to have_received(:drain).with(group: :management)
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

  it 'waits for active threads to finish after requesting stop' do
    worker_started = Queue.new
    finish_worker = Queue.new
    stop_requested = Queue.new
    manager = Struct.new(:stop_requested) do
      def request_stop
        stop_requested << true
      end
    end.new(stop_requested)

    worker = Thread.new do
      worker_started << true
      finish_worker.pop
    end

    reaper.start
    reaper.add(worker, manager)
    worker_started.pop
    wait_until { reaper.export == [[worker, manager]] }

    stop_thread = Thread.new { reaper.stop }
    stop_requested.pop

    expect(stop_thread).to be_alive

    finish_worker << true
    join_thread!(stop_thread)

    expect(reaper.export).to be_empty
  ensure
    finish_worker << true if worker&.alive?
    join_thread!(worker) if worker
  end

  it 'detaches durable lifecycle effects when the daemon process is stopping' do
    worker_started = Queue.new
    finish_worker = Queue.new
    worker = Thread.new do
      worker_started << true
      finish_worker.pop
    end

    reaper.start
    reaper.add(worker, nil, group: :durable_lifecycle)
    worker_started.pop
    wait_until { reaper.export == [[worker, nil]] }

    reaper.stop

    expect(worker).to be_alive
    expect(reaper.export).to be_empty
  ensure
    finish_worker << true if worker&.alive?
    join_thread!(worker) if worker
  end

  it 'detaches lifecycle hook callbacks when the daemon process is stopping' do
    worker_started = Queue.new
    finish_worker = Queue.new
    worker = Thread.new do
      worker_started << true
      finish_worker.pop
    end

    reaper.start
    reaper.add(worker, nil, group: :user_control)
    worker_started.pop
    wait_until { reaper.export == [[worker, nil]] }

    reaper.stop

    expect(worker).to be_alive
    expect(reaper.export).to be_empty
  ensure
    finish_worker << true if worker&.alive?
    join_thread!(worker) if worker
  end

  it 'does not track durable lifecycle effects added after stop begins' do
    first_worker_started = Queue.new
    finish_first_worker = Queue.new
    first_stop_requested = Queue.new
    first_manager = Struct.new(:stop_requested) do
      def request_stop
        stop_requested << true
      end
    end.new(first_stop_requested)
    first_worker = Thread.new do
      first_worker_started << true
      finish_first_worker.pop
    end

    late_worker_started = Queue.new
    finish_late_worker = Queue.new
    late_worker = Thread.new do
      late_worker_started << true
      finish_late_worker.pop
    end

    reaper.start
    reaper.add(first_worker, first_manager)
    first_worker_started.pop
    late_worker_started.pop
    wait_until { reaper.export == [[first_worker, first_manager]] }

    stop_thread = Thread.new { reaper.stop }
    first_stop_requested.pop
    reaper.add(late_worker, nil, group: :durable_lifecycle)
    finish_first_worker << true
    join_thread!(stop_thread)

    expect(late_worker).to be_alive
    expect(reaper.export).to be_empty
  ensure
    finish_first_worker << true if first_worker&.alive?
    finish_late_worker << true if late_worker&.alive?
    join_thread!(first_worker) if first_worker
    join_thread!(late_worker) if late_worker
  end

  it 'requests stop from managers added after stop begins' do
    first_worker_started = Queue.new
    finish_first_worker = Queue.new
    first_stop_requested = Queue.new
    first_manager = Struct.new(:stop_requested) do
      def request_stop
        stop_requested << true
      end
    end.new(first_stop_requested)

    first_worker = Thread.new do
      first_worker_started << true
      finish_first_worker.pop
    end

    late_worker_started = Queue.new
    finish_late_worker = Queue.new
    late_stop_requested = Queue.new
    late_manager = Struct.new(:stop_requested, :finish_worker) do
      def request_stop
        stop_requested << true
        finish_worker << true
      end
    end.new(late_stop_requested, finish_late_worker)

    late_worker = Thread.new do
      late_worker_started << true
      finish_late_worker.pop
    end

    reaper.start
    reaper.add(first_worker, first_manager)
    first_worker_started.pop
    late_worker_started.pop
    wait_until { reaper.export == [[first_worker, first_manager]] }

    stop_thread = Thread.new { reaper.stop }
    first_stop_requested.pop

    reaper.add(late_worker, late_manager)
    late_stop_requested.pop

    expect(stop_thread).to be_alive

    finish_first_worker << true
    join_thread!(stop_thread)

    expect(reaper.export).to be_empty
  ensure
    finish_first_worker << true if first_worker&.alive?
    finish_late_worker << true if late_worker&.alive?
    join_thread!(first_worker) if first_worker
    join_thread!(late_worker) if late_worker
  end

  it 'drains selected groups without stopping other groups' do
    management_worker_started = Queue.new
    finish_management_worker = Queue.new
    management_stop_requested = Queue.new
    management_manager = Struct.new(:stop_requested) do
      def request_stop
        stop_requested << true
      end
    end.new(management_stop_requested)

    management_worker = Thread.new do
      management_worker_started << true
      finish_management_worker.pop
    end

    user_control_worker_started = Queue.new
    finish_user_control_worker = Queue.new
    user_control_stop_requested = Queue.new
    user_control_manager = Struct.new(:stop_requested, :finish_worker) do
      def request_stop
        stop_requested << true
        finish_worker << true
      end
    end.new(user_control_stop_requested, finish_user_control_worker)

    user_control_worker = Thread.new do
      user_control_worker_started << true
      finish_user_control_worker.pop
    end

    reaper.start
    reaper.add(management_worker, management_manager, group: :management)
    management_worker_started.pop
    user_control_worker_started.pop
    wait_until { reaper.export == [[management_worker, management_manager]] }

    drain_thread = Thread.new { reaper.drain(group: :management) }
    management_stop_requested.pop

    reaper.add(user_control_worker, user_control_manager, group: :user_control)
    wait_until do
      reaper.export == [
        [management_worker, management_manager],
        [user_control_worker, user_control_manager]
      ]
    end

    expect(drain_thread).to be_alive
    expect(user_control_stop_requested).to be_empty

    finish_management_worker << true
    join_thread!(drain_thread)

    expect(user_control_worker).to be_alive
    expect(user_control_stop_requested).to be_empty

    reaper.stop

    expect(user_control_stop_requested).to be_empty
    expect(reaper.export).to be_empty
  ensure
    finish_management_worker << true if management_worker&.alive?
    finish_user_control_worker << true if user_control_worker&.alive?
    join_thread!(management_worker) if management_worker
    join_thread!(user_control_worker) if user_control_worker
  end

  it 'raises on unknown queue commands' do
    reaper.instance_variable_get(:@queue) << :bogus

    expect do
      reaper.send(:run)
    end.to raise_error(RuntimeError, /unknown command 'bogus'/)
  end
end
