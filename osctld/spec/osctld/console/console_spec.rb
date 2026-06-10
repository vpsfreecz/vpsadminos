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

      def ct; end

      def dataset; end
    end
  end

  def build_ct(ephemeral: false, manipulated: false)
    pool = Struct.new(:name).new('tank')
    Struct.new(:pool, :id, :ephemeral, :manipulated, keyword_init: true) do
      def ephemeral?
        ephemeral
      end

      def is_being_manipulated?
        manipulated
      end

      def unmount(force:); end

      def mount(force:); end
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
    attempts = [Errno::ENOENT, Errno::ECONNREFUSED, socket]
    allow(console).to receive(:wake)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new) do
      ret = attempts.shift
      raise ret if ret.is_a?(Class)

      ret
    end

    console.connect(123, '/tmp/tty0.sock')

    expect(console.instance_variable_get(:@opened)).to be(true)
    expect(console.send(:tty_pid)).to eq(123)
    expect(console.send(:tty_in_io)).to equal(socket)
    expect(console.send(:tty_out_io)).to equal(socket)
    expect(console).to have_received(:wake)
    expect(console).to have_received(:sleep).twice
  end

  it 'raises when tty0 never becomes available' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect { console.connect(123, '/tmp/tty0.sock') }.to raise_error(Errno::ENOENT)
  end

  it 'raises when tty0 keeps refusing connections' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)

    expect { console.connect(123, '/tmp/tty0.sock') }.to raise_error(Errno::ECONNREFUSED)
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

    console.send(:on_close)

    expect(console).to have_received(:on_ct_stop)
    expect(OsCtld::ThreadReaper).to have_received(:add).with(thread, nil)
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
