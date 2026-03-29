# frozen_string_literal: true

require 'osctld/trash_bin'

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

  def build_pool
    Struct.new(:name, :trash_bin_ds, keyword_init: true).new(
      name: 'tank',
      trash_bin_ds: 'tank/trash'
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
end
