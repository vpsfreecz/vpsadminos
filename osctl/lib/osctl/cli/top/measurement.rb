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

      if netifs == :all
        host.netif_stats.get_stats_for_all.each do |netif, st|
          ret[:tx][:bytes] += st[:tx][:bytes]
          ret[:tx][:packets] += st[:tx][:packets]
          ret[:rx][:bytes] += st[:rx][:bytes]
          ret[:rx][:packets] += st[:rx][:packets]
        end

      else
        netifs.each do |netif|
          next unless netif.veth

          st = host.netif_stats.get_stats_for(netif.veth)

          # rx/tx are reversed within the container
          ret[:tx][:bytes] += st[:rx][:bytes]
          ret[:tx][:packets] += st[:rx][:packets]
          ret[:rx][:bytes] += st[:tx][:bytes]
          ret[:rx][:packets] += st[:tx][:packets]
        end
      end

      ret
    end

    def add_zfs_io_stats
      if dataset.nil?
        st = host.objsets.aggregate_stats

        data[:zfsio] = {
          ios: {
            w: st.write_ios,
            r: st.read_ios,
          },
          bytes: {
            w: st.write_bytes,
            r: st.read_bytes,
          },
        }
      else
        ds = host.objsets[dataset]

        if ds
          st = ds.aggregate_stats
          data[:zfsio] = {
            ios: {
              w: st.write_ios,
              r: st.read_ios,
            },
            bytes: {
              w: st.write_bytes,
              r: st.read_bytes,
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
  end
end
