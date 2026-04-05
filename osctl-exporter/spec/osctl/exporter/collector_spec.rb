# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collector do
  before do
    reset_singleton(described_class)
  end

  after do
    reset_singleton(described_class)
  end

  it 'creates collector configs for all expected collector classes with distinct registries' do
    manager = described_class.instance
    configs = manager.send(:collectors)

    expect(configs.map(&:collector_class)).to eq(
      [
        OsCtl::Exporter::Collectors::ZpoolTxgs,
        OsCtl::Exporter::Collectors::OsCtld,
        OsCtl::Exporter::Collectors::Pool,
        OsCtl::Exporter::Collectors::Container,
        OsCtl::Exporter::Collectors::Exportfs,
        OsCtl::Exporter::Collectors::KernelKeyring,
        OsCtl::Exporter::Collectors::Sysctl,
        OsCtl::Exporter::Collectors::ZpoolList,
        OsCtl::Exporter::Collectors::ZpoolStatus,
        OsCtl::Exporter::Collectors::CpuScheduler,
        OsCtl::Exporter::Collectors::HealthCheck
      ]
    )
    expect(configs.map(&:registry).map(&:object_id).uniq.size).to eq(configs.size)
    expect(configs.map(&:collector_instance).all?).to be(true)
  end

  it 'starts one thread per unique interval and stops by joining them' do
    manager = described_class.instance
    thread_double = instance_double(Thread, join: nil)
    allow(manager).to receive(:log)
    allow(Thread).to receive(:new).and_return(thread_double, thread_double, thread_double, thread_double)

    manager.start

    expect(manager.send(:threads).size).to eq(manager.send(:collectors).map(&:interval).uniq.size)

    manager.stop

    expect(thread_double).to have_received(:join).exactly(manager.send(:collectors).map(&:interval).uniq.size).times
    expect(manager.send(:threads)).to be_empty
  end

  it 'returns collector instances by class' do
    manager = described_class.instance
    container = manager.get_collector_by_class(OsCtl::Exporter::Collectors::Container)

    expect(container).to be_a(OsCtl::Exporter::Collectors::Container)
    expect(manager.get_collector_by_class(Class.new)).to be_nil
  end

  it 'isolates failures in one collector from the others in the same interval' do
    manager = described_class.instance
    client = instance_double(OsCtl::Exporter::OsCtldClient, connected?: true)
    allow(client).to receive(:try_to_connect).and_yield
    allow(manager).to receive(:log)

    bad_registry = instance_double(OsCtl::Exporter::Registry)
    good_registry = instance_double(OsCtl::Exporter::Registry)
    allow(bad_registry).to receive(:atomic_replace).and_yield
    allow(good_registry).to receive(:atomic_replace).and_yield

    bad_collector = instance_double(OsCtl::Exporter::Collectors::Base)
    good_collector = instance_double(OsCtl::Exporter::Collectors::Base, run_collect: nil)
    allow(bad_collector).to receive(:run_collect).and_raise(RuntimeError, 'boom')

    bad_class = Class.new(OsCtl::Exporter::Collectors::Base)
    good_class = Class.new(OsCtl::Exporter::Collectors::Base)
    bad_cfg = described_class::CollectorConfig.new(bad_class, false, 30, bad_collector, bad_registry)
    good_cfg = described_class::CollectorConfig.new(good_class, false, 30, good_collector, good_registry)

    manager.send(:collect, client, [bad_cfg, good_cfg])

    expect(good_collector).to have_received(:run_collect).with(client)
    expect(manager).to have_received(:log).with(
      :warn,
      "Collector #{bad_class} failed: boom (RuntimeError)"
    )
  end
end
