module OsCtl::Lib
  class Zfs::ObjsetStats::Parser
    # @param pool [String]
    # @return [Zfs::ObjsetStats::PoolTree]
    def read(pool)
      tree = Zfs::ObjsetStats::PoolTree.new(pool)

      Dir.glob(File.join('/proc/spl/kstat/zfs', pool, 'objset-*')).each do |f|
        objset = parse_objset(f)
        tree << objset if objset
      end

      tree.build
      tree
    end

    protected
    def parse_objset(path)
      objset = Zfs::ObjsetStats::Objset.new

      File.open(path) do |f|
        # Skip the first two lines
        f.readline
        f.readline

        # Parse the rest
        f.each_line do |line|
          name, type, data = line.strip.split

          case name
          when 'dataset_name'
            objset.dataset_name = data
          when 'writes'
            objset.write_ios = data.to_i
          when 'nwritten'
            objset.write_bytes = data.to_i
          when 'reads'
            objset.read_ios = data.to_i
          when 'nread'
            objset.read_bytes = data.to_i
          end
        end
      end

      objset.dataset_name ? objset : nil
    end
  end
end
