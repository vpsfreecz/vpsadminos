# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/utils/switch_user'
require 'osctld/console'
require 'osctld/container/stop_handler'

RSpec.describe OsCtld::Container::StopHandler do
  let(:run_conf_class) do
    Class.new do
      def aborted?; end

      def destroy_dataset_on_stop?; end

      def reboot?; end

      def fulfil_exit; end

      def claim_exit_handling; end

      def ct; end

      def dataset; end
    end
  end

  def build_ct(ephemeral: false, manipulated: false)
    pool = Struct.new(:name).new('tank')
    Struct.new(:pool, :id, :ephemeral, :manipulated, :past_run_conf, :state, keyword_init: true) do
      def ephemeral?
        ephemeral
      end

      def is_being_manipulated?
        manipulated
      end

      def get_past_run_conf
        past_run_conf
      end

      def forget_past_run_conf(expected)
        self.past_run_conf = nil if past_run_conf.equal?(expected)
      end

      def update_hints; end

      def unmount(force:); end

      def mount(force:); end
    end.new(pool:, id: 'ct1', ephemeral:, manipulated:, state: :stopped)
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

  describe '#run without a console wrapper' do
    let(:ct) { build_ct(manipulated: true) }
    let(:rc) do
      instance_double(run_conf_class, aborted?: false, destroy_dataset_on_stop?: false,
                                      reboot?: false, fulfil_exit: nil, claim_exit_handling: true)
    end

    before do
      stub_writeout_daemon(true)
      stub_const('OsCtld::CpuScheduler', Class.new do
        def self.unschedule_ct(_ct); end
      end)
      allow(OsCtld::CpuScheduler).to receive(:unschedule_ct)
      ct.past_run_conf = rc
    end

    it 'fulfills the promise only after the shared writeback cleanup' do
      allow(ct).to receive(:unmount)
      allow(ct).to receive(:mount)

      described_class.new(ct, rc).run

      expect(ct).to have_received(:unmount).with(force: true).ordered
      expect(ct).to have_received(:mount).with(force: false).ordered
      expect(rc).to have_received(:fulfil_exit).ordered
      expect(ct.past_run_conf).to be_nil
    end

    it 'does not fulfill the promise when cleanup fails' do
      allow(ct).to receive(:mount).and_raise('writeback failed')

      expect { described_class.new(ct, rc).run }.to raise_error(RuntimeError, 'writeback failed')
      expect(rc).not_to have_received(:fulfil_exit)
      expect(ct.past_run_conf).to equal(rc)
    end

    it 'does not repeat cleanup already claimed by another callback' do
      allow(rc).to receive(:claim_exit_handling).and_return(false)

      described_class.new(ct, rc).run

      expect(rc).not_to have_received(:fulfil_exit)
      expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
    end

    it 'does not clean a replacement past run' do
      other = Object.new
      ct.past_run_conf = other

      described_class.new(ct, rc).run

      expect(rc).not_to have_received(:fulfil_exit)
      expect(ct.past_run_conf).to equal(other)
      expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
    end
  end

  it 'runs recovery cleanup for aborted containers' do
    stub_writeout_daemon(false)
    ct = build_ct
    console = described_class.new(ct)
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

  it 'uses the recovery taint gate after an improper stop' do
    ct = build_ct
    console = described_class.new(ct)
    recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
      def initialize(*); end
    end)
    recovery = instance_double(recovery_class, cleanup_or_taint: false)
    allow(recovery_class).to receive(:new).with(ct).and_return(recovery)

    console.send(:handle_improper_ct_stop)

    expect(recovery_class).to have_received(:new).with(ct)
    expect(recovery).to have_received(:cleanup_or_taint)
  end

  it 'writes back dirtied pages for persistent containers when configured' do
    stub_writeout_daemon(true)
    ct = build_ct
    console = described_class.new(ct)
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
    console = described_class.new(ct)
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
    console = described_class.new(ct)
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
    console = described_class.new(build_ct)
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
