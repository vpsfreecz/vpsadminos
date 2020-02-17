module OsCtl::Lib
  class Zfs::PoolIOStat
    attr_reader :pool
    attr_reader :nread, :nwritten, :reads, :writes, :wtime, :wlentime, :wupdate,
      :rtime, :rlentime, :rupdate, :wcnt, :rcnt

    # @param pool [String]
    def initialize(pool)
      @pool = pool
      parse
    end

    protected
    def parse
      File.open(File.join('/proc/spl/kstat/zfs', pool, 'io')) do |f|
        f.readline
        f.readline

        stats = f.readline.strip.split

        %w(nread nwritten reads writes wtime wlentime wupdate rtime rlentime
           rupdate wcnt rcnt).each do |param|
          instance_variable_set("@#{param}", stats.shift.to_i)
        end
      end
    end
  end
end
