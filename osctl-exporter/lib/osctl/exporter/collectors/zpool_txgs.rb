require 'osctl/exporter/collectors/base'
require 'libosctl'

module OsCtl::Exporter
  class Collectors::ZpoolTxgs < Collectors::Base
    Stats = Struct.new(:count, :bytes, :operations, :times, keyword_init: true)

    TIMES = %i(otime qtime wtime stime)
    BYTES = %i(ndirty nread nwritten)
    OPERATIONS = %i(reads writes)

    def setup
      @mutex = Mutex.new
      @txgs_stats = {}
      @worker = Thread.new { read_txgs }

      add_metric(
        :zpool_txgs_count,
        :gauge,
        :zpool_txgs_count,
        docstring: 'Number of transaction groups',
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
      sync do
        @txgs_stats.each do |pool, stats|
          @zpool_txgs_count.set(stats.count, labels: {pool: pool})

          BYTES.each do |v|
            metrics["zpool_txgs_#{v}_bytes"].set(
              stats.bytes[v],
              labels: {pool: pool},
            )
          end

          OPERATIONS.each do |v|
            metrics["zpool_txgs_#{v}"].set(
              stats.operations[v],
              labels: {pool: pool},
            )
          end

          TIMES.each do |v|
            metrics["zpool_txgs_#{v}_nanoseconds"].set(
              stats.times[v],
              labels: {pool: pool},
            )
          end
        end
      end
    end

    protected
    def read_txgs
      previous = {}

      loop do
        pools_txgs = OsCtl::Lib::Zfs::ZpoolTransactionGroups.new

        # Remove stats of removed pools
        pool_names = pools_txgs.pools.keys
        @txgs_stats.delete_if { |pool, _| !pool_names.include?(pool) }
        previous.delete_if { |pool, _| !pool_names.include?(pool) }

        # Calculate values
        pools_txgs.each do |pool, txgs|
          cur_txgs =
            if previous[pool]
              txgs.since(previous[pool])
            else
              txgs
            end

          sync do
            @txgs_stats[pool] ||= Stats.new(
              count: 0,
              bytes: {},
              operations: {},
              times: {},
            )

            @txgs_stats[pool].count += cur_txgs.length

            last_txg = txgs.last_committed
            next if last_txg.nil?

            BYTES.each do |v|
              @txgs_stats[pool].bytes[v] = last_txg.send(v)
            end

            OPERATIONS.each do |v|
              @txgs_stats[pool].operations[v] = last_txg.send(v)
            end

            TIMES.each do |v|
              @txgs_stats[pool].times[v] = last_txg.send(:"#{v}_ns")
            end
          end

          previous[pool] = txgs
        end

        txg_timeout = File.read('/sys/module/zfs/parameters/zfs_txg_timeout').to_i

        if txg_timeout > 5
          sleep(5)
        else
          sleep([txg_timeout - 1, 1].max)
        end
      end
    end

    def sync(&block)
      @mutex.synchronize(&block)
    end
  end
end
