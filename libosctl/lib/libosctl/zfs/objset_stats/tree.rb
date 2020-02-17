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
  end
end
