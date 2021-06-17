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
      @aggregated_stats = nil
    end

    def aggregate_stats(into: nil)
      if @aggregated_stats
        if into
          into.write_ios += @aggregated_stats.write_ios
          into.write_bytes += @aggregated_stats.write_bytes
          into.read_ios += @aggregated_stats.read_ios
          into.read_bytes += @aggregated_stats.read_bytes
        else
          return @aggregated_stats
        end
      end

      st = AggregatedStats.new(write_ios, write_bytes, read_ios, read_bytes)

      subdatasets.each do |subset|
        subset.aggregate_stats(into: st)
      end

      @aggregated_stats = st

      if into
        into.write_ios += st.write_ios
        into.write_bytes += st.write_bytes
        into.read_ios += st.read_ios
        into.read_bytes += st.read_bytes
        into
      else
        st
      end
    end
  end
end
