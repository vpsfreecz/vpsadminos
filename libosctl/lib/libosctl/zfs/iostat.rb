require 'thread'

module OsCtl::Lib
  class Zfs::IOStat
    PoolStats = Struct.new(
      :pool,
      :alloc,
      :free,
      :io_read,
      :io_written,
      :bytes_read,
      :bytes_written
    ) do
      def <<(other)
        self.alloc = nil
        self.free = nil
        self.io_read += other.io_read
        self.io_written += other.io_written
        self.bytes_read += other.bytes_read
        self.bytes_written += other.bytes_written
      end
    end

    # @return [Array<String>]
    attr_reader :pools

    # @return [Integer]
    attr_reader :interval

    # @param pools [Array<String>, nil]
    # @param interval [Integer]
    def initialize(pools: nil, interval: 1)
      @pools = pools
      @interval = interval
      @current_stats = {}
      @accumulated_stats = {}
      @current_all = nil
      @accumulated_all = PoolStats.new(nil, nil, nil, 0, 0, 0, 0)
      @mutex = Mutex.new
    end

    def start
      return if pools.is_a?(Array) && pools.empty?

      args = ['zpool', 'iostat', '-Hpy']
      args.concat(pools) if pools
      args << interval.to_s

      r, w = IO.pipe
      @reader = Thread.new { parser(r) }
      @iostat_pid = Process.spawn(*args, out: w)
      w.close
    end

    def started?
      !reader.nil?
    end

    def stop
      if iostat_pid
        Process.kill('TERM', iostat_pid)
        Process.wait(iostat_pid)
        @iostat_pid = nil
      end

      return unless reader

      reader.join
      @reader = nil
    end

    # @param pool [String]
    def add_pool(pool)
      @pools ||= []
      return if pools.include?(pool)

      pools << pool
      stop if started?
      start
      nil
    end

    # @param pool [String]
    def remove_pool(pool)
      return if pools.nil? || !pools.include?(pool)

      pools.delete(pool)
      return unless started?

      stop

      sync do
        current_stats.delete(pool)
        accumulated_stats.delete(pool)
      end

      start
      nil
    end

    # @param new_pools [Array<String>, nil]
    def pools=(new_pools)
      removed_pools = (@pools || []) - (new_pools || [])
      @pools = new_pools.clone
      return unless started?

      stop

      sync do
        removed_pools.each do |pool|
          current_stats.delete(pool)
          accumulated_stats.delete(pool)
        end
      end

      start
    end

    # @param pool [String]
    # @return [PoolStats]
    def current_pool(pool)
      sync { current_stats[pool] }
    end

    # @param pool [String]
    # @return [PoolStats]
    def accumulated_pool(pool)
      sync { accumulated_stats[pool] }
    end

    # @return [PoolStats]
    def current_all
      sync { @current_all }
    end

    # @return [PoolStats]
    def accumulated_all
      sync { @accumulated_all }
    end

    protected

    attr_reader :iostat_pid, :mutex, :reader,
                :current_stats, :accumulated_stats

    def parser(r)
      r.each_line do |line|
        pool, alloc, free, rio, wio, rbytes, wbytes = line.strip.split("\t")
        st = PoolStats.new(
          pool,
          alloc.to_i,
          free.to_i,
          rio.to_i,
          wio.to_i,
          rbytes.to_i,
          wbytes.to_i
        )

        sync do
          current_stats[pool] = st

          if accumulated_stats.has_key?(pool)
            accumulated_stats[pool] << st
          else
            accumulated_stats[pool] = st
          end

          @current_all = st
          @accumulated_all << st
        end
      end
    rescue IOError
    end

    def sync(&)
      mutex.synchronize(&)
    end
  end
end
