# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/utils/switch_user'
require 'osctld/console'
require 'osctld/console/console'

RSpec.describe OsCtld::Console::Console do
  let(:run_conf_class) do
    Class.new do
      def aborted?; end

      def destroy_dataset_on_stop?; end

      def reboot?; end

      def fulfil_exit; end

      def claim_exit_cleanup; end

      def start_pending?; end

      def runtime_started?; end

      def runtime_launching?; end

      def run_id; end

      def ct; end

      def dataset; end
    end
  end

  def build_ct(ephemeral: false, manipulated: false)
    pool = Struct.new(:name).new('tank')
    Struct.new(:pool, :id, :ephemeral, :manipulated, keyword_init: true) do
      def state
        :stopped
      end

      def ephemeral?
        ephemeral
      end

      def is_being_manipulated?
        manipulated
      end

      def unmount(force:); end

      def mount(force:); end

      def stop_run(_run_conf)
        true
      end

      def get_past_run_conf; end

      def get_pending_run_conf; end

      def update_hints; end

      def forget_past_run_conf(_run_conf); end
    end.new(pool:, id: 'ct1', ephemeral:, manipulated:)
  end

  def stub_writeout_daemon(enabled)
    config = Struct.new(:enabled) do
      def writeout_dirtied_pages?
        enabled
      end
    end.new(enabled)
    daemon = Struct.new(:config).new(config)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def stub_daemon(stopping:)
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end

      def stopping?; end
    end)
    daemon = instance_double(daemon_class, stopping?: stopping)
    allow(daemon_class).to receive(:get).and_return(daemon)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  it 'keeps open as a no-op for tty0' do
    console = described_class.new(build_ct, 0)

    expect(console.open).to be_nil
  end

  it 'retries UNIX socket connection races until they succeed' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    run_conf = Object.new
    attempts = [Errno::ENOENT, Errno::ECONNREFUSED, socket]
    allow(console).to receive(:wake)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new) do
      ret = attempts.shift
      raise ret if ret.is_a?(Class)

      ret
    end

    console.connect(123, '/tmp/tty0.sock', run_conf)

    expect(console.instance_variable_get(:@opened)).to be(true)
    expect(console.send(:tty_pid)).to eq(123)
    expect(console.send(:tty_in_io)).to equal(socket)
    expect(console.send(:tty_out_io)).to equal(socket)
    expect(console.send(:close_context)).to equal(run_conf)
    expect(console).to have_received(:wake)
    expect(console).to have_received(:sleep).twice
  end

  it 'attaches an already connected socket without allocating another one' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    run_conf = Object.new
    allow(console).to receive(:wake)
    allow(UNIXSocket).to receive(:new)

    console.attach(nil, socket, run_conf)

    expect(UNIXSocket).not_to have_received(:new)
    expect(console.instance_variable_get(:@opened)).to be(true)
    expect(console.send(:tty_in_io)).to equal(socket)
    expect(console.send(:tty_out_io)).to equal(socket)
    expect(console.send(:close_context)).to equal(run_conf)
  end

  it 'observes EOF but leaves input disabled until the exact run is ready' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    run_conf = Object.new
    allow(console).to receive(:wake)

    console.attach(nil, socket, run_conf, ready: false)

    expect(console.instance_variable_get(:@opened)).to be(false)
    expect(console.send(:tty_in_io)).to be_nil
    expect(console.send(:tty_out_io)).to equal(socket)
    expect(console.activate(run_conf)).to be(true)
    expect(console.instance_variable_get(:@opened)).to be(true)
    expect(console.send(:tty_in_io)).to equal(socket)
  end

  it 'does not activate a stale console generation' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    allow(console).to receive(:wake)
    console.attach(nil, socket, Object.new, ready: false)

    expect(console.activate(Object.new)).to be(false)
    expect(console.send(:tty_in_io)).to be_nil
  end

  it 'rolls back a preconnected socket when console wakeup fails' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    allow(console).to receive(:wake).and_raise(IOError, 'wake failed')

    expect do
      console.attach(nil, socket, Object.new)
    end.to raise_error(IOError, 'wake failed')

    expect(console.instance_variable_get(:@opened)).to be(false)
    expect(console.send(:tty_in_io)).to be_nil
    expect(console.send(:tty_out_io)).to be_nil
    expect(console.send(:close_context)).to be_nil
  end

  it 'raises when tty0 never becomes available' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect do
      console.connect(123, '/tmp/tty0.sock', Object.new)
    end.to raise_error(Errno::ENOENT)
  end

  it 'raises when tty0 keeps refusing connections' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)

    expect do
      console.connect(123, '/tmp/tty0.sock', Object.new)
    end.to raise_error(Errno::ECONNREFUSED)
  end

  it 'schedules container stop handling through ThreadReaper when the console closes' do
    console = described_class.new(build_ct, 0)
    reaper = Class.new do
      def self.add(_thread, _manager); end
    end
    thread = instance_double(Thread)
    stub_const('OsCtld::ThreadReaper', reaper)
    allow(OsCtld::ThreadReaper).to receive(:add)
    allow(Thread).to receive(:new).and_yield.and_return(thread)
    allow(console).to receive(:on_ct_stop)
    run_conf = Object.new

    console.send(:on_close, run_conf)

    expect(console).to have_received(:on_ct_stop).with(run_conf)
    expect(OsCtld::ThreadReaper).to have_received(:add).with(thread, nil)
  end

  it 'retries stop handler allocation without a lifecycle cutoff' do
    stub_daemon(stopping: false)
    console = described_class.new(build_ct, 0)
    reaper = stub_const('OsCtld::ThreadReaper', Class.new do
      def self.add(_thread, _manager); end
    end)
    thread = instance_double(Thread)
    attempts = 0
    allow(Thread).to receive(:new) do
      attempts += 1
      raise ThreadError, 'temporarily unavailable' if attempts < 3

      thread
    end
    allow(reaper).to receive(:add)
    allow(console).to receive(:sleep)

    console.send(:on_close, Object.new)

    expect(attempts).to eq(3)
    expect(console).to have_received(:sleep).with(0.1).ordered
    expect(console).to have_received(:sleep).with(0.2).ordered
    expect(reaper).to have_received(:add).with(thread, nil)
  end

  it 'leaves stop cleanup to the next daemon when shutting down' do
    stub_daemon(stopping: true)
    console = described_class.new(build_ct, 0)
    reaper = stub_const('OsCtld::ThreadReaper', Class.new do
      def self.add(_thread, _manager); end
    end)
    allow(Thread).to receive(:new).and_raise(ThreadError, 'temporarily unavailable')
    allow(reaper).to receive(:add)
    allow(console).to receive(:sleep)
    allow(console).to receive(:log)

    console.send(:wrapper_exited, Object.new)

    expect(console).not_to have_received(:sleep)
    expect(reaper).not_to have_received(:add)
    expect(console).to have_received(:log).with(
      :info,
      console.ct,
      'osctld is shutting down, leaving stop cleanup for the next daemon'
    )
  end

  it 'cleans up the exact replacement run while an old reboot run is retained' do
    stub_writeout_daemon(false)
    ct = build_ct
    console = described_class.new(ct, 0)
    old_run = instance_double(run_conf_class)
    run_id = instance_double(Object, to_s: 'tank:ct1:new')
    active_run = instance_double(
      run_conf_class,
      claim_exit_cleanup: true,
      start_pending?: true,
      runtime_launching?: true,
      aborted?: false,
      reboot?: false,
      run_id:
    )
    cpu_scheduler = stub_const('OsCtld::CpuScheduler', Class.new do
      def self.unschedule_ct(_ct); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)

    allow(ct).to receive(:get_past_run_conf).and_return(old_run)
    allow(ct).to receive(:stop_run).with(active_run).and_return(true)
    allow(ct).to receive(:forget_past_run_conf).with(active_run)
    allow(cpu_scheduler).to receive(:unschedule_ct)
    allow(eventd).to receive(:report)
    allow(console).to receive(:handle_ct_stop).with(active_run)

    console.send(:on_ct_stop, active_run)

    expect(ct).to have_received(:stop_run).with(active_run)
    expect(active_run).to have_received(:claim_exit_cleanup)
    expect(console).to have_received(:handle_ct_stop).with(active_run)
    expect(eventd).to have_received(:report).with(
      :ct_start_failed,
      pool: 'tank',
      id: 'ct1',
      run_id: 'tank:ct1:new',
      message: 'container wrapper exited before the runtime started'
    )
  end

  it 'runs recovery cleanup for aborted containers' do
    stub_writeout_daemon(false)
    ct = build_ct
    console = described_class.new(ct, 0)
    ctrc = instance_double(
      run_conf_class,
      aborted?: true,
      destroy_dataset_on_stop?: false,
      reboot?: false,
      fulfil_exit: nil,
      ct:
    )
    recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
      def initialize(*); end
    end)
    recovery = instance_double(recovery_class, cleanup_or_taint: nil)
    allow(recovery_class).to receive(:new).with(ct).and_return(recovery)

    console.send(:handle_ct_stop, ctrc)

    expect(recovery_class).to have_received(:new).with(ct)
    expect(recovery).to have_received(:cleanup_or_taint)
    expect(ctrc).to have_received(:fulfil_exit)
  end

  it 'writes back dirtied pages for persistent containers when configured' do
    stub_writeout_daemon(true)
    ct = build_ct
    console = described_class.new(ct, 0)
    ctrc = instance_double(
      run_conf_class,
      aborted?: false,
      destroy_dataset_on_stop?: false,
      reboot?: false,
      fulfil_exit: nil
    )
    allow(ct).to receive(:unmount)
    allow(ct).to receive(:mount)

    console.send(:handle_ct_stop, ctrc)

    expect(ct).to have_received(:unmount).with(force: true)
    expect(ct).to have_received(:mount).with(force: false)
    expect(ctrc).to have_received(:fulfil_exit)
  end

  it 'frees run datasets when destroy-on-stop is enabled' do
    stub_writeout_daemon(false)
    ct = build_ct
    console = described_class.new(ct, 0)
    ctrc = instance_double(
      run_conf_class,
      aborted?: false,
      destroy_dataset_on_stop?: true,
      reboot?: false,
      fulfil_exit: nil,
      dataset: instance_double(OsCtl::Lib::Zfs::Dataset)
    )
    stub_const('OsCtld::GarbageCollector', Class.new do
      def self.free_container_run_dataset(_ctrc, _dataset); end
    end)
    allow(OsCtld::GarbageCollector).to receive(:free_container_run_dataset)

    console.send(:handle_ct_stop, ctrc)

    expect(OsCtld::GarbageCollector).to have_received(:free_container_run_dataset).with(ctrc, ctrc.dataset)
  end

  it 'deletes ephemeral containers after a clean stop' do
    stub_writeout_daemon(false)
    ct = build_ct(ephemeral: true, manipulated: false)
    console = described_class.new(ct, 0)
    ctrc = instance_double(
      run_conf_class,
      aborted?: false,
      destroy_dataset_on_stop?: false,
      reboot?: false,
      fulfil_exit: nil
    )
    delete_class = Class.new do
      def self.run(**); end
    end
    stub_const('OsCtld::Commands::Container::Delete', delete_class)
    allow(delete_class).to receive(:run)

    console.send(:handle_ct_stop, ctrc)

    expect(delete_class).to have_received(:run).with(
      pool: 'tank',
      id: 'ct1',
      force: true,
      manipulation_lock: 'wait'
    )
  end

  it 'reboots containers that request a reboot' do
    stub_writeout_daemon(false)
    console = described_class.new(build_ct, 0)
    ctrc = instance_double(
      run_conf_class,
      aborted?: false,
      destroy_dataset_on_stop?: false,
      reboot?: true,
      fulfil_exit: nil
    )
    allow(console).to receive(:reboot_ct)
    allow(console).to receive(:sleep)

    console.send(:handle_ct_stop, ctrc)

    expect(console).to have_received(:reboot_ct)
  end
end
