module OsCtl::Lib
  module Zfs::ObjsetStats
    def self.read_pools(pools)
      tree = Zfs::ObjsetStats::Tree.new
      pools.each { |pool| tree << read_pool(pool) }
      tree
    end

    def self.read_pool(pool)
      parser = Zfs::ObjsetStats::Parser.new
      parser.read(pool)
    end
  end
end
