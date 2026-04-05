# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::ZpoolTxgs do
  it 'exports last-txg and all-txg metrics for multiple pools' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)
    txg1 = txg_info(
      txg: 1,
      ndirty: 10,
      nread: 11,
      nwritten: 12,
      reads: 13,
      writes: 14,
      otime_ns: 15,
      qtime_ns: 16,
      wtime_ns: 17,
      stime_ns: 18
    )
    txg2 = txg_info(
      txg: 2,
      ndirty: 20,
      nread: 21,
      nwritten: 22,
      reads: 23,
      writes: 24,
      otime_ns: 25,
      qtime_ns: 26,
      wtime_ns: 27,
      stime_ns: 28
    )
    txg3 = txg_info(
      txg: 3,
      ndirty: 30,
      nread: 31,
      nwritten: 32,
      reads: 33,
      writes: 34,
      otime_ns: 35,
      qtime_ns: 36,
      wtime_ns: 37,
      stime_ns: 38
    )

    allow(OsCtl::Lib::Zfs::ZpoolTransactionGroups).to receive(:new).and_return(
      'tank' => [txg1, txg2],
      'backup' => [txg3]
    )

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:zpool_txgs_count))).to eq(
      { { pool: 'tank' } => 2.0, { pool: 'backup' } => 3.0 }
    )
    expect(metric_values(registry.get(:zpool_txgs_last_ndirty_bytes))).to eq(
      { { pool: 'tank' } => 20.0, { pool: 'backup' } => 30.0 }
    )
    expect(metric_values(registry.get(:zpool_txgs_reads))).to include(
      { pool: 'tank', txg: '1' } => 13.0,
      { pool: 'tank', txg: '2' } => 23.0,
      { pool: 'backup', txg: '3' } => 33.0
    )
    expect(metric_values(registry.get(:zpool_txgs_stime_nanoseconds))).to include(
      { pool: 'tank', txg: '2' } => 28.0
    )
  end
end
