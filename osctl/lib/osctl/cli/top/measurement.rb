require 'pp'
require 'osctl/cli/cgroup_params'

module OsCtl::Cli
  class Top::Measurement
    class Error < StandardError ; end

    include CGroupParams

    attr_reader :time, :data

    def initialize(host, subsystems, group_path, dataset, netifs)
      @host = host
      @subsystems = subsystems
      @group_path = group_path
      @dataset = dataset
      @netifs = netifs
      @data = {}
    end

    def measure
      @time = Time.now

      data.update(cg_read_stats(
        subsystems,
        group_path,
        %i(cpu_time cpu_stat memory nproc),
        true
      ))

      add_zfs_io_stats

      data.update(netif_stats)

    rescue SystemCallError => e
      raise Error, e.message
    end

    def diff_from(other, mode)
      do_diff_from(other.data, data, mode, time - other.time)
    end

    protected
    attr_reader :host, :subsystems, :group_path, :dataset, :netifs

    def do_diff_from(other, mine, mode, delta)
      ret = {}

      other.each do |k, v|
        if v.is_a?(Hash)
          ret[k] = do_diff_from(v, mine[k], mode, delta)

        elsif %i(memory nproc).include?(k)
          ret[k] = mine[k]

        else
          if mode == :realtime
            ret[k] = ((mine[k] - v) / delta.to_f).round
          else
            ret[k] = mine[k] - v
          end

          ret[k] = 0 if ret[k] < 0
        end
      end

      ret
    end

    def netif_stats
      ret = {tx: {bytes: 0, packets: 0}, rx: {bytes: 0, packets: 0}}

      netifs.each do |netif|
        next unless netif.veth

        %i(bytes packets).each do |type|
          # rx/tx are reversed within the container
          {rx: :tx, tx: :rx}.each do |host_dir, ct_dir|
            ret[ct_dir][type] = read_netif_stats(netif, host_dir, type)
          end
        end
      end

      ret
    end

    def read_netif_stats(netif, dir, type)
      ret = File.read("/sys/class/net/#{netif.veth}/statistics/#{dir}_#{type}")
      ret.strip.to_i

    rescue Errno::ENOENT
      0
    end

    def add_zfs_io_stats
      if dataset.nil?
        data[:zfsio] = read_zfs_host_io_stats
      else
        ds = host.objsets[dataset]

        if ds
          st = ds.aggregate_stats
          data[:zfsio] = {
            ios: {
              w: ds.write_ios,
              r: ds.read_ios,
            },
            bytes: {
              w: ds.write_bytes,
              r: ds.read_bytes,
            },
          }
        else
          data[:zfsio] = {
            ios: {w: 0, r: 0},
            bytes: {w: 0, r: 0},
          }
        end
      end
    end

    def read_zfs_host_io_stats
      ret = {
        ios: {w: 0, r: 0},
        bytes: {w: 0, r: 0},
      }

      host.pools.each do |pool|
        st = OsCtl::Lib::Zfs::PoolIOStat.new(pool)
        ret[:ios][:w] += st.writes
        ret[:ios][:r] += st.reads
        ret[:bytes][:w] += st.nwritten
        ret[:bytes][:r] += st.nread
      end

      ret
    end
  end
end
