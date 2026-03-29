# frozen_string_literal: true

# rubocop:disable RSpec/SubjectStub

require 'osctld/hint_updater'

RSpec.describe OsCtld::HintUpdater do
  subject(:updater) { described_class.new(pool) }

  let(:pool) { Struct.new(:name).new('tank') }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(id:, pool:, running:)
    Struct.new(:id, :pool, :running, keyword_init: true) do
      def running?
        running
      end

      def update_hints; end
    end.new(id:, pool:, running:)
  end

  it 'raises when started twice' do
    thread = instance_double(Thread, join: nil)
    allow(Thread).to receive(:new).and_return(thread)

    updater.start

    expect do
      updater.start
    end.to raise_error(RuntimeError, 'already started')
  ensure
    updater.stop
  end

  it 'clears the queue, wakes the worker, and joins it on stop' do
    queue = instance_double(OsCtl::Lib::Queue)
    thread = instance_double(Thread, join: nil)
    updater.instance_variable_set(:@ct_queue, queue)
    updater.instance_variable_set(:@ct_thread, thread)
    allow(queue).to receive(:clear)
    allow(queue).to receive(:<<)

    updater.stop

    expect(queue).to have_received(:clear)
    expect(queue).to have_received(:<<).with(:stop)
    expect(thread).to have_received(:join)
    expect(updater.instance_variable_get(:@ct_thread)).to be_nil
  end

  it 'updates only running containers from the configured pool' do
    ct1 = build_ct(id: 'ct1', pool:, running: true)
    ct2 = build_ct(id: 'ct2', pool: Struct.new(:name).new('pool2'), running: true)
    ct3 = build_ct(id: 'ct3', pool:, running: false)
    queue = instance_double(OsCtl::Lib::Queue)
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.get; end
    end)
    allow(queue).to receive(:pop).and_return(:tick, :stop)
    updater.instance_variable_set(:@ct_queue, queue)
    allow(db).to receive(:get).and_return([ct1, ct2, ct3])
    allow(ct1).to receive(:update_hints)
    allow(ct2).to receive(:update_hints)
    allow(ct3).to receive(:update_hints)
    allow(updater).to receive(:sleep)

    updater.send(:run_ct_updates)

    expect(ct1).to have_received(:update_hints)
    expect(ct2).not_to have_received(:update_hints)
    expect(ct3).not_to have_received(:update_hints)
  end

  it 'logs update failures and continues with later containers' do
    ct1 = build_ct(id: 'ct1', pool:, running: true)
    ct2 = build_ct(id: 'ct2', pool:, running: true)
    queue = instance_double(OsCtl::Lib::Queue)
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.get; end
    end)
    allow(queue).to receive(:pop).and_return(:tick, :stop)
    updater.instance_variable_set(:@ct_queue, queue)
    allow(db).to receive(:get).and_return([ct1, ct2])
    allow(ct1).to receive(:update_hints).and_raise(StandardError, 'boom')
    allow(ct2).to receive(:update_hints)
    allow(updater).to receive(:sleep)
    allow(updater).to receive(:denixstorify).and_return(['line'])

    updater.send(:run_ct_updates)

    expect(ct2).to have_received(:update_hints)
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn,
      /Unable to update hints: boom \(StandardError\)/
    )
  end
end

# rubocop:enable RSpec/SubjectStub
