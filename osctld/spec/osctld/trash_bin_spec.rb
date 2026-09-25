# frozen_string_literal: true

require 'osctld/lockable'
require 'osctld/garbage_collector'
require 'osctld/trash_bin'
require 'osctld/storage_activity'
require 'timeout'

RSpec.describe OsCtld::TrashBin do
  def stub_trash_daemon(prune_interval: 0.01)
    trash_cfg = Struct.new(:prune_interval).new(prune_interval)
    daemon_cfg = Struct.new(:trash_bin).new(trash_cfg)
    daemon = Struct.new(:config).new(daemon_cfg)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def build_pool(activity: nil)
    Struct.new(
      :name, :trash_bin_ds, :storage_activity, :storage_activity_instance_uuid,
      :garbage_collector, :trash_bin, keyword_init: true
    ).new(
      name: 'tank',
      trash_bin_ds: 'tank/trash',
      storage_activity: activity,
      storage_activity_instance_uuid: activity&.attach_pool('tank'),
      garbage_collector: instance_double(OsCtld::GarbageCollector, started?: true)
    )
  end

  it 'reports started? from the worker lifecycle' do
    stub_trash_daemon
    trash = described_class.new(build_pool)

    expect(trash.started?).to be(false)

    trash.start
    expect(trash.started?).to be(true)

    trash.stop
    expect(trash.started?).to be(false)
  end

  it 'moves datasets into trash and records metadata' do
    trash = described_class.new(build_pool)
    child = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1/sub')
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', to_s: 'tank/ct1')
    allow(dataset).to receive(:list).and_return([dataset, child])
    t = Time.at(1700)
    allow(trash).to receive(:trash_path).with(dataset).and_return(['tank/trash/ct1.1700.abcdef', t])
    allow(trash).to receive(:zfs)

    trash.add_dataset(dataset)

    expect(trash).to have_received(:zfs).with(:set, 'canmount=noauto', 'tank/ct1/sub')
    expect(trash).to have_received(:zfs).with(:unmount, nil, 'tank/ct1/sub')
    expect(trash).to have_received(:zfs).with(:set, 'canmount=noauto', 'tank/ct1')
    expect(trash).to have_received(:zfs).with(:unmount, nil, 'tank/ct1')
    expect(trash).to have_received(:zfs).with(:rename, nil, 'tank/ct1 tank/trash/ct1.1700.abcdef')
    expect(trash).to have_received(:zfs).with(
      :set,
      'org.vpsadminos.osctl.trash-bin:original_name=tank/ct1 ' \
      'org.vpsadminos.osctl.trash-bin:trashed_at=1700',
      'tank/trash/ct1.1700.abcdef'
    )
  end

  it 'tolerates unmount errors for datasets that are not currently mounted' do
    trash = described_class.new(build_pool)
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', to_s: 'tank/ct1')
    allow(dataset).to receive(:list).and_return([dataset])
    allow(trash).to receive(:trash_path).and_return(['tank/trash/ct1.1700.abcdef', Time.at(1700)])
    allow(trash).to receive(:zfs) do |cmd, _, name|
      next unless cmd == :unmount && name == 'tank/ct1'

      raise OsCtld::SystemCommandFailed.new('zfs unmount', 1, 'not currently mounted')
    end

    expect { trash.add_dataset(dataset) }.not_to raise_error
  end

  it 'counts a synchronous move before the first ZFS effect' do
    tracker = OsCtld::StorageActivity.new
    pool = build_pool(activity: tracker)
    trash = described_class.new(pool)
    pool.trash_bin = trash
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', to_s: 'tank/ct1')
    allow(dataset).to receive(:list).and_return([dataset])
    allow(trash).to receive(:trash_path).and_return(['tank/trash/ct1.1700.abcdef', Time.at(1700)])
    observed = []
    allow(trash).to receive(:zfs) do |cmd, _, _|
      observed << tracker.snapshot('tank', pool:)[:counts][:trash_move] if cmd == :set
    end

    trash.add_dataset(dataset)

    expect(observed).not_to be_empty
    expect(observed).to all(eq(pending: 0, running: 1))
    expect(tracker.snapshot('tank', pool:)[:counts][:trash_move]).to eq(pending: 0, running: 0)
  end

  it 'counts a timer prune until its scan completes' do
    stub_trash_daemon(prune_interval: 0.01)
    allow(OsCtl::Lib::Logger).to receive(:log)
    tracker = OsCtld::StorageActivity.new
    pool = build_pool(activity: tracker)
    trash = described_class.new(pool)
    pool.trash_bin = trash
    entered = Queue.new
    release = Queue.new
    allow(trash).to receive(:prune_datasets) do
      entered << true
      release.pop
    end

    trash.start
    Timeout.timeout(2) { entered.pop }
    expect(tracker.snapshot('tank', pool:)[:counts][:trash_prune]).to eq(pending: 0, running: 1)

    stop_thread = Thread.new { trash.stop }
    release << true
    Timeout.timeout(2) { stop_thread.join }
    expect(tracker.snapshot('tank', pool:)[:counts][:trash_prune]).to eq(pending: 0, running: 0)
  end

  it 'keeps a failed move unknown after the running counter clears' do
    tracker = OsCtld::StorageActivity.new
    pool = build_pool(activity: tracker)
    trash = described_class.new(pool)
    pool.trash_bin = trash
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', to_s: 'tank/ct1')
    allow(dataset).to receive(:list).and_return([dataset])
    allow(trash).to receive(:zfs).and_raise(
      OsCtld::SystemCommandFailed.new('zfs set', 1, 'unknown result')
    )

    expect { trash.add_dataset(dataset) }.to raise_error(OsCtld::SystemCommandFailed)

    sample = tracker.snapshot('tank', pool:)
    expect(sample[:counts][:trash_move]).to eq(pending: 0, running: 0)
    expect(sample[:unknown_reasons]).to include('trash_job_failed')
    expect(sample[:idle]).to be(false)
  end
end
