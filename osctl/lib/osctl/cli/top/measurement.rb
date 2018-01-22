require 'pp'

module OsCtl::Cli
  class Top::Measurement
    include CGroupParams

    attr_reader :time, :data

    def initialize(subsystems, group_path, netifs)
      @subsystems = subsystems
      @group_path = group_path
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

      data[:blkio] = cg_blkio_stats(
        subsystems,
        group_path,
        %i(bytes iops)
      )

      data.update(netif_stats)
    end

    def diff_from(other, mode)
      do_diff_from(other.data, data, mode, time - other.time)
    end

    protected
    attr_reader :subsystems, :group_path, :netifs

    def do_diff_from(other, mine, mode, delta)
      ret = {}

      other.each do |k, v|
        if v.is_a?(Hash)
          ret[k] = do_diff_from(v, mine[k], mode, delta)

        elsif %i(memory nproc).include?(k)
          ret[k] = v

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
  end
end
