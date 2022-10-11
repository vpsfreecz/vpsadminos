require 'osctl/exporter/collectors/base'
require 'libosctl'

module OsCtl::Exporter
  class Collectors::ZpoolTxgs < Collectors::Base
    TIMES = %i(otime qtime wtime stime)
    BYTES = %i(ndirty nread nwritten)
    OPERATIONS = %i(reads writes)

    def setup
      add_metric(
        :zpool_txgs_count,
        :gauge,
        :zpool_txgs_count,
        docstring: 'Total count of transaction groups',
        labels: [:pool],
      )

      BYTES.each do |v|
        add_metric(
          "zpool_txgs_#{v}_bytes",
          :gauge,
          :"zpool_txgs_#{v}_bytes",
          docstring: "#{v} in bytes",
          labels: [:pool],
        )
      end

      OPERATIONS.each do |v|
        add_metric(
          "zpool_txgs_#{v}",
          :gauge,
          :"zpool_txgs_#{v}",
          docstring: "Number of operations",
          labels: [:pool],
        )
      end

      TIMES.each do |v|
        add_metric(
          "zpool_txgs_#{v}_nanoseconds",
          :gauge,
          :"zpool_txgs_#{v}_nanoseconds",
          docstring: "#{v} in nanoseconds",
          labels: [:pool],
        )
      end
    end

    def collect(client)
      pools_txgs = OsCtl::Lib::Zfs::ZpoolTransactionGroups.new

      pools_txgs.each do |pool, txgs|
        last_txg = txgs.last

        @zpool_txgs_count.set(last_txg.txg, labels: {pool: pool})

        BYTES.each do |v|
          metrics["zpool_txgs_#{v}_bytes"].set(
            last_txg.send(v),
            labels: {pool: pool},
          )
        end

        OPERATIONS.each do |v|
          metrics["zpool_txgs_#{v}"].set(
            last_txg.send(v),
            labels: {pool: pool},
          )
        end

        TIMES.each do |v|
          metrics["zpool_txgs_#{v}_nanoseconds"].set(
            last_txg.send(:"#{v}_ns"),
            labels: {pool: pool},
          )
        end
      end
    end

    def sync(&block)
      @mutex.synchronize(&block)
    end
  end
end
