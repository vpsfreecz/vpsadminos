module OsCtl::Lib
  class Zfs::ObjsetStats::Tree
    def initialize
      @pool_trees = {}
    end

    # @param pool_tree [Zfs::ObjsetStats::PoolTree]
    def <<(pool_tree)
      @pool_trees[ pool_tree.pool ] = pool_tree
    end

    # @param dataset [String]
    def [](dataset)
      pool = dataset.split('/').first
      @pool_trees[pool][dataset]
    end

    def aggregate_stats(into: nil)
      st = Zfs::ObjsetStats::Objset::AggregatedStats.new(0, 0, 0, 0)

      @pool_trees.each_value do |pool_tree|
        pool_tree.aggregate_stats(into: st)
      end

      st
    end
  end
end
