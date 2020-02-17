module OsCtl::Lib
  class Zfs::ObjsetStats::Objset
    AggregatedStats = Struct.new(
      :write_ios,
      :write_bytes,
      :read_ios,
      :read_bytes,
    )

    attr_accessor :dataset_name, :write_ios, :write_bytes, :read_ios, :read_bytes
    attr_reader :subdatasets

    def initialize
      @write_ios = 0
      @write_bytes = 0
      @read_ios = 0
      @read_bytes = 0
      @subdatasets = []
    end

    def aggregate_stats(into: nil)
      st =
        if into
          into.write_ios += write_ios
          into.write_bytes += write_bytes
          into.read_ios += read_ios
          into.read_bytes += read_bytes
          into
        else
          AggregatedStats.new(write_ios, write_bytes, read_ios, read_bytes)
        end

      subdatasets.each do |subset|
        subset.aggregate_stats(into: st)
      end

      st
    end
  end
end
