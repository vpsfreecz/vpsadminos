# frozen_string_literal: true

require 'osctld/storage_activity'
require 'osctld/attributes'
require 'osctld/pool'
require 'osctld/garbage_collector'
require 'osctld/trash_bin'

RSpec.describe OsCtld::StorageActivity do
  def pool(instance_uuid, gc_alive: true, trash_alive: true)
    Struct.new(
      :storage_activity_instance_uuid, :garbage_collector, :trash_bin,
      keyword_init: true
    ).new(
      storage_activity_instance_uuid: instance_uuid,
      garbage_collector: instance_double(OsCtld::GarbageCollector, started?: gc_alive),
      trash_bin: instance_double(OsCtld::TrashBin, started?: trash_alive)
    )
  end

  it 'counts queued work through running completion without an idle pop gap' do
    tracker = described_class.new
    instance_uuid = tracker.attach_pool('tank')
    current_pool = pool(instance_uuid)
    tracker.state('tank', instance_uuid, 'active')

    initial = tracker.snapshot('tank', pool: current_pool)
    expect(initial).to include(
      version: 1, coverage: 'gc_trash_v1', unknown: false, overflow: false, idle: true
    )
    expect(initial[:daemon_boot_uuid]).to match(/\A[0-9a-f-]{36}\z/)

    tracker.enqueue('tank', instance_uuid, :run_gc)
    pending = tracker.snapshot('tank', pool: current_pool)
    expect(pending[:counts][:run_gc]).to eq(pending: 1, running: 0)
    expect(pending[:unknown]).to be(false)
    expect(pending[:idle]).to be(false)

    tracker.start_queued('tank', instance_uuid, :run_gc)
    running = tracker.snapshot('tank', pool: current_pool)
    expect(running[:counts][:run_gc]).to eq(pending: 0, running: 1)
    expect(running[:idle]).to be(false)

    tracker.finish('tank', instance_uuid, :run_gc)
    finished = tracker.snapshot('tank', pool: current_pool)
    expect(finished[:idle]).to be(true)
    expect([initial, pending, running, finished].map { |v| v[:generation] }).to eq(
      [4, 6, 8, 10]
    )
  end

  it 'counts timer work and synchronous moves before they can act' do
    tracker = described_class.new
    instance_uuid = tracker.attach_pool('tank')
    current_pool = pool(instance_uuid)
    tracker.state('tank', instance_uuid, 'active')

    tracker.start_direct('tank', instance_uuid, :trash_prune)
    tracker.start_direct('tank', instance_uuid, :trash_move)
    sample = tracker.snapshot('tank', pool: current_pool)

    expect(sample[:counts][:trash_prune]).to eq(pending: 0, running: 1)
    expect(sample[:counts][:trash_move]).to eq(pending: 0, running: 1)
    expect(sample[:idle]).to be(false)

    tracker.finish('tank', instance_uuid, :trash_prune)
    tracker.finish('tank', instance_uuid, :trash_move)
    expect(tracker.snapshot('tank', pool: current_pool)[:idle]).to be(true)
  end

  it 'retains unknown after worker loss and across pool reimport' do
    tracker = described_class.new
    first = tracker.attach_pool('tank')
    tracker.state('tank', first, 'active')
    lost = tracker.snapshot('tank', pool: pool(first, gc_alive: false))
    expect(lost[:unknown_reasons]).to include('worker_dead')
    expect(lost[:unknown]).to be(true)

    tracker.state('tank', first, 'absent')
    second = tracker.attach_pool('tank')
    tracker.state('tank', second, 'active')
    sample = tracker.snapshot('tank', pool: pool(second))

    expect(second).not_to eq(first)
    expect(sample[:generation]).to be > lost[:generation]
    expect(sample[:unknown_reasons]).to include('worker_dead')
    expect(sample[:idle]).to be(false)

    tracker.finish('tank', first, :run_gc)
    expect(tracker.snapshot('tank', pool: pool(second))[:unknown_reasons]).to include(
      'stale_instance_event'
    )
  end

  it 'bounds counts and keeps overflow unknown after completion' do
    tracker = described_class.new
    instance_uuid = tracker.attach_pool('tank')
    tracker.state('tank', instance_uuid, 'active')
    tracker.registered('tank', instance_uuid, described_class::MAX_COUNT + 1)

    sample = tracker.snapshot('tank', pool: pool(instance_uuid))
    expect(sample[:registered_run_datasets]).to eq(described_class::MAX_COUNT)
    expect(sample[:unknown_reasons]).to include('count_overflow')
    expect(sample).to include(unknown: true, overflow: true)
    expect(sample[:idle]).to be(false)
  end

  it 'reports absent pools without inventing worker coverage' do
    tracker = described_class.new
    sample = tracker.snapshot('missing', pool: nil)

    expect(sample).to include(state: 'absent', unknown: true, overflow: false, idle: false)
    expect(sample[:pool_instance_uuid]).to be_nil
    expect(sample[:unknown_reasons]).to eq(['pool_absent'])
  end

  it 'keeps a pool lifecycle generation through export and reimport' do
    tracker = described_class.new
    daemon = Struct.new(:storage_activity).new(tracker)
    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)

    first = OsCtld::Pool.new('tank', 'tank')
    first.instance_variable_set(
      '@autostart_plan', instance_double(OsCtld::AutoStart::Plan, started?: false)
    )
    first.instance_variable_set('@trash_bin', instance_double(OsCtld::TrashBin, started?: false))
    first.instance_variable_set(
      '@garbage_collector', instance_double(OsCtld::GarbageCollector, started?: false)
    )
    importing = tracker.snapshot('tank', pool: first)

    first.begin_stop
    stopping = tracker.snapshot('tank', pool: first)
    first.storage_activity_absent
    absent = tracker.snapshot('tank', pool: nil)
    second = OsCtld::Pool.new('tank', 'tank')
    reimporting = tracker.snapshot('tank', pool: second)

    expect([importing, stopping, absent, reimporting].map { |v| v[:state] }).to eq(
      %w[importing stopping absent importing]
    )
    expect([importing, stopping, absent, reimporting].map { |v| v[:generation] }).to eq(
      [2, 4, 6, 8]
    )
    expect(reimporting[:pool_instance_uuid]).not_to eq(importing[:pool_instance_uuid])
  end
end
