module OsCtl::Lib
  # Version-agnostic interface for reading CGroup parameters
  class CGroup::PathReader
    class Base
      include Utils::Humanize

      def initialize
        @cache = {}
      end

      protected
      attr_reader :cache

      def meminfo
        @@meminfo ||= MemInfo.new
      end

      def cache_param(path, name)
        path_cache = cache[path]

        if path_cache
          name_cache = path_cache[name]
          return name_cache if name_cache
        end

        cache[path] ||= {}
        cache[path][name] = yield(path, name)
      end
    end

    class V1 < Base
      def initialize(subsystems, path)
        super()
        @subsystems = subsystems
        @path = path
      end

      def read_stats_param(field, precise)
        case field
        when :memory
          t = read_memory_usage
          Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

        when :kmemory
          t = read_cgparam(
            :memory,
            path,
            'memory.kmem.usage_in_bytes'
          ).to_i
          Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

        when :memory_pct
          limit = read_memory_limit
          usage = read_memory_usage
          t = usage.to_f / limit * 100
          Cli::Presentable.new(t, formatted: precise ? nil : humanize_percent(t))

        when :cpu_us, :cpu_user_us, :cpu_system_us
          all = read_cgparam(
            :cpuacct,
            path,
            'cpuacct.usage'
          ).to_i / 1_000

          user = read_cgparam(
            :cpuacct,
            path,
            'cpuacct.usage_user'
          ).to_i / 1_000

          sys = read_cgparam(
            :cpuacct,
            path,
            'cpuacct.usage_sys'
          ).to_i / 1_000

          {
            cpu_us: Cli::Presentable.new(
              all, formatted: precise ? nil : humanize_time_us(all)
            ),
            cpu_user_us: Cli::Presentable.new(
              user, formatted: precise ? nil : humanize_time_us(user)
            ),
            cpu_system_us: Cli::Presentable.new(
              sys, formatted: precise ? nil : humanize_time_us(sys)
            ),
          }

        when :cpu_hz, :cpu_user_hz, :cpu_system_hz
          Hash[
            read_cgparam(
              :cpuacct,
              path,
              'cpuacct.stat'
            ).split("\n").map do |line|
              type, hz = line.split(' ')
              [:"cpu_#{type}_hz", hz.to_i]
            end
          ]

        when :nproc
          read_cgparam(
            :pids,
            path,
            'pids.current'
          ).to_i

        else
          nil
        end
      end

      # @return [Integer]
      def read_memory_usage
        read_cgparam(:memory, path, 'memory.memsw.usage_in_bytes').to_i
      end

      # @return [Integer]
      def read_memory_limit
        unlimited = 9223372036854771712

        limit_path =
          if path.end_with?('/user-owned')
            path.split('/')[0..-2].join('/')
          else
            path
          end

        v = read_cgparam(:memory, limit_path, 'memory.memsw.limit_in_bytes').to_i
        return v if v != unlimited

        v = read_cgparam(:memory, limit_path, 'memory.limit_in_bytes').to_i
        return v if v != unlimited

        meminfo.total * 1024
      end

      def read_params(params)
        ret = {}

        read_path =
          if path.end_with?('/user-owned')
            path.split('/')[0..-2].join('/')
          else
            path
          end

        params.each do |par|
          v_raw =
            begin
              read_cgparam(parse_subsystem(par.to_s).to_sym, read_path, par.to_s)
            rescue Errno::ENOENT
              nil
            end

          if v_raw.nil?
            v_target = nil
          else
            v_int = v_raw.to_i

            v_target =
              if v_int.to_s == v_raw
                Cli::Presentable.new(v_int, formatted: v_raw, exported: v_raw)
              else
                v_raw
              end
          end

          ret[par.to_sym] = v_target
        end

        ret
      end

      def list_available_params
        params = []

        subsystems.each_value do |subsys_path|
          cgpath = File.join(subsys_path, path)

          begin
            entries = Dir.entries(cgpath)
          rescue Errno::ENOENT
            # the /osctl cgroup does not exist when there are no containers
            return params
          end

          entries.each do |v|
            next if %w(. .. notify_on_release release_agent tasks).include?(v)
            next if v.start_with?('cgroup.')

            st = File.stat(File.join(cgpath, v))
            next if st.directory?

            # Ignore files that do not have read by user permission
            next if (st.mode & 0400) != 0400

            params << v
          end
        end

        params.uniq!
        params.sort!
        params
      end

      protected
      attr_reader :subsystems, :path

      def read_cgparam(subsys_name, group_path, param)
        cache_param(group_path, param) do
          File.read(File.join(subsystems[subsys_name], group_path, param)).strip
        end
      end

      def parse_subsystem(param)
        param.split('.').first
      end
    end

    class V2 < Base
      # @param cg_root [String] path to CGroup mountpoint
      # @param path [String] CGroup path relative to cg_root
      def initialize(cg_root, path)
        super()
        @cg_root = cg_root
        @path = path
      end

      def read_stats_param(field, precise)
        case field
        when :memory
          t = read_cgparam(path, 'memory.current').to_i
          Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

        when :kmemory
          nil

        when :memory_pct
          limit = read_memory_limit
          usage = read_cgparam(path, 'memory.current').to_i
          t = usage.to_f / limit * 100
          Cli::Presentable.new(t, formatted: precise ? nil : humanize_percent(t))

        when :cpu_us, :cpu_user_us, :cpu_system_us
          stat = read_cpu_stat

          {
            cpu_us: Cli::Presentable.new(
              stat[:all], formatted: precise ? nil : humanize_time_us(stat[:all])
            ),
            cpu_user_us: Cli::Presentable.new(
              stat[:user], formatted: precise ? nil : humanize_time_us(stat[:user])
            ),
            cpu_system_us: Cli::Presentable.new(
              stat[:system], formatted: precise ? nil : humanize_time_us(stat[:system])
            ),
          }

        when :cpu_hz, :cpu_user_hz, :cpu_system_hz
          stat = read_cpu_stat

          {
            cpu_user_hz: stat[:user] / (1_000_000 / OsProcess::TICS_PER_SECOND),
            cpu_system_hz: stat[:system] / (1_000_000 / OsProcess::TICS_PER_SECOND),
          }

        when :nproc
          read_cgparam(path, 'pids.current').to_i

        else
          nil
        end
      end

      # @param path [String] path of chosen group, relative to the subsystem
      # @return [Integer]
      def read_memory_limit
        unlimited = 'max'

        limit_path =
          if path.end_with?('/user-owned')
            path.split('/')[0..-2].join('/')
          else
            path
          end

        v = read_cgparam(limit_path, 'memory.max').to_i
        return v if v != unlimited

        meminfo.total * 1024
      end

      # @return [Hash] cpu usage in microseconds
      def read_cpu_stat
        params = Hash[read_cgparam(path, 'cpu.stat').strip.split("\n").map(&:split)]

        {
          all: params['usage_usec'].to_i,
          user: params['user_usec'].to_i,
          system: params['system_usec'].to_i,
        }
      end

      # @return [Hash]
      def read_params(params)
        ret = {}

        read_path =
          if path.end_with?('/user-owned')
            path.split('/')[0..-2].join('/')
          else
            path
          end

        params.each do |par|
          v_raw =
            begin
              read_cgparam(read_path, par.to_s)
            rescue Errno::ENOENT
              nil
            end

          if v_raw.nil?
            v_target = nil
          else
            v_int = v_raw.to_i

            v_target =
              if v_int.to_s == v_raw
                Cli::Presentable.new(v_int, formatted: v_raw, exported: v_raw)
              else
                v_raw
              end
          end

          ret[par.to_sym] = v_target
        end

        ret
      end

      def list_available_params
        params = []

        cgpath = File.join(cg_root, path)

        begin
          entries = Dir.entries(cgpath)
        rescue Errno::ENOENT
          # the /osctl cgroup does not exist when there are no containers
          return params
        end

        entries.each do |v|
          next if %w(. .. notify_on_release release_agent tasks).include?(v)
          next if v.start_with?('cgroup.')

          st = File.stat(File.join(cgpath, v))
          next if st.directory?

          # Ignore files that do not have read by user permission
          next if (st.mode & 0400) != 0400

          params << v
        end

        params.sort!
        params
      end

      protected
      attr_reader :cg_root, :path

      def read_cgparam(group_path, param)
        cache_param(group_path, param) do
          File.read(File.join(cg_root, group_path, param)).strip
        end
      end
    end

    # @param subsystems [Hash] subsystem => absolute path, ignored on CGroupv2
    # @param path [String] path of chosen group, relative to the subsystem
    def initialize(subsystems, path)
      @cg_reader =
        if CGroup.v1?
          V1.new(subsystems, path)
        else
          V2.new(CGroup::FS, path)
        end
    end

    # Read and interpret selected CGroup parameters
    # @param params [Array] parameters to read
    # @param precise [Boolean] humanize parameter values?
    # @return [Hash] parameter => value
    def read_stats(params, precise)
      ret = {}

      params.each do |field|
        begin
          next if ret[field]

          v = cg_reader.read_stats_param(field, precise)
          next if v.nil?

          if v.is_a?(Hash)
            ret.update(v)
          else
            ret[field] = v
          end

        rescue Errno::ENOENT
          ret[field] = nil
        end
      end

      ret
    end

    # Read selected CGroup parameters
    # @param params [Array]
    # @return [Hash]
    def read_params(params)
      cg_reader.read_params(params)
    end

    # List available CGroup parameters
    # @return Array<String>
    def list_available_params
      cg_reader.list_available_params
    end

    protected
    attr_reader :cg_reader
  end
end
