require 'libosctl'
require 'osctl/cli/cgroup_params'

module OsCtl::Cli
  class Top::Measurement
    class Error < StandardError; end

    include CGroupParams

    attr_reader :time, :data, :core_error

    def initialize(host, subsystems, group_path, dataset, netifs, enable_netif: true, enable_zfs: true)
      @host = host
      @subsystems = subsystems
      @group_path = group_path
      @dataset = dataset
      @netifs = netifs
      @data = {}
      @enable_netif = enable_netif
      @enable_zfs = enable_zfs
    end

    def measure
      @time = Time.now
      cg_reader = OsCtl::Lib::CGroup::PathReader.new(subsystems, group_path)

      data.update(cg_reader.read_stats(
                    %i[cpu_us cpu_hz cpu_limit memory memory_limit nproc],
                    true
                  ))

      validate_core
      data[:cpu_limit] = nil unless data.has_key?(:cpu_limit)
      data[:memory_limit] = nil unless data.has_key?(:memory_limit)

      data[:zfsio] = nil
      if @enable_zfs
        begin
          add_zfs_io_stats
        rescue StandardError
          data[:zfsio] = nil
        end
      end

      data[:tx] = data[:rx] = nil
      if @enable_netif
        begin
          data.update(netif_stats)
        rescue StandardError
          data[:tx] = data[:rx] = nil
        end
      end
    rescue SystemCallError => e
      raise Error, e.message
    end

    def diff_from(other, mode)
      do_diff_from(other.data, data, mode, time - other.time)
    end

    def delta_error(other)
      return 'invalid_window' unless time > other.time

      %i[cpu_us cpu_user_us cpu_system_us cpu_hz cpu_user_hz cpu_system_hz].each do |key|
        next if data[key].nil? || other.data[key].nil?
        return 'counter_reset' if raw(data[key]) < raw(other.data[key])
      end
      nil
    end

    protected

    attr_reader :host, :subsystems, :group_path, :dataset, :netifs

    def raw(value)
      value.is_a?(OsCtl::Lib::Cli::Presentable) ? value.raw : value
    end

    def nonnegative?(value)
      value = raw(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def validate_core
      @core_error = nil
      unless %i[cpu_user_hz cpu_system_hz memory].all? { |k| nonnegative?(data[k]) }
        @core_error = 'missing_cgroup_value'
      end
      %i[cpu_limit memory_limit].each do |k|
        next unless data.has_key?(k)

        if data[k].nil?
          @core_error = 'missing_cgroup_value'
        elsif !nonnegative?(data[k]) || raw(data[k]) <= 0
          @core_error = 'invalid_limit'
        end
      end
    end

    def do_diff_from(other, mine, mode, delta)
      ret = {}

      (other.keys | mine.keys).each do |k|
        v = other[k]
        if %i[cpu_limit memory memory_limit nproc].include?(k)
          ret[k] = mine[k]

        elsif v.nil? || mine[k].nil?
          ret[k] = nil

        elsif v.is_a?(Hash)
          ret[k] = do_diff_from(v, mine[k], mode, delta)

        else
          ret[k] = if mode == :realtime
                     ((mine[k] - v) / delta.to_f).round
                   else
                     mine[k] - v
                   end

          ret[k] = 0 if ret[k] < 0
        end
      end

      ret
    end

    def netif_stats
      ret = { tx: { bytes: 0, packets: 0 }, rx: { bytes: 0, packets: 0 } }

      if netifs == :all
        host.netif_stats.get_stats_for_all.each_value do |st|
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
            r: st.read_ios
          },
          bytes: {
            w: st.write_bytes,
            r: st.read_bytes
          }
        }
      else
        ds = host.objsets[dataset]

        if ds
          st = ds.aggregate_stats
          data[:zfsio] = {
            ios: {
              w: st.write_ios,
              r: st.read_ios
            },
            bytes: {
              w: st.write_bytes,
              r: st.read_bytes
            }
          }
        else
          data[:zfsio] = {
            ios: { w: 0, r: 0 },
            bytes: { w: 0, r: 0 }
          }
        end
      end
    end
  end
end
