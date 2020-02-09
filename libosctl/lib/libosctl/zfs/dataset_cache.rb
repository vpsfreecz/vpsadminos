module OsCtl::Lib
  class Zfs::DatasetCache
    # @param datasets [Array<Zfs::Dataset>]
    def initialize(datasets)
      @index = {}
      rebuild_index(datasets)
    end

    # @param name [String]
    # @return [Zfs::Dataset, nil]
    def [](name)
      @index[name]
    end

    protected
    def rebuild_index(datasets)
      @index.clear
      datasets.each { |ds| @index[ds.name] = ds }
    end
  end
end
