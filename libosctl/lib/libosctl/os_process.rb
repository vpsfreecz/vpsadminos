require 'etc'

module OsCtl::Lib
  # Interface to system processes, reading information from `/proc`
  class OsProcess
    TICS_PER_SECOND = Etc.sysconf(Etc::SC_CLK_TCK).to_i

    def self.system_start_time
      unless @system_start_time
        @system_start_time = Time.now - File.read('/proc/uptime').strip.split.first.to_i
      end

      @system_start_time
    end

    # Process ID
    # @return [Integer]
    attr_reader :pid

    # Parent process ID
    # @return [Integer]
    attr_reader :ppid

    # Process group ID
    # @return [Integer]
    attr_reader :pgrp

    # @return [Array]
    attr_reader :nspid

    # @return [Integer]
    attr_reader :ruid

    # @return [Integer]
    attr_reader :euid

    # @return [Integer]
    attr_reader :rgid

    # @return [Integer]
    attr_reader :egid

    # @return [String]
    attr_reader :state

    # @return [String]
    attr_reader :name

    # Virtual memory size
    # @return [Integer]
    attr_reader :vmsize

    # Resident set size
    # @return [Integer]
    attr_reader :rss

    # @return [Integer]
    attr_reader :nice

    # @return [Integer]
    attr_reader :num_threads

    # Number of seconds this process was scheduled in user mode
    # @return [Integer]
    attr_reader :user_time

    # Number of seconds this process was scheduled in kernel mode
    # @return [Integer]
    attr_reader :sys_time

    # Time when the process was started
    # @return [Time]
    attr_reader :start_time

    # @param pid [Integer]
    def initialize(pid)
      @path = File.join('/proc', pid.to_s)
      @pid = pid
      @cache = {}
      @id_maps = {}

      volatile do
        parse_stat
        parse_status
      end
    end

    # @return [OsProcess]
    def parent
      self.class.new(ppid)
    end

    # @return [OsProcess]
    def grandparent
      parent.parent
    end

    # Return PID as seen in the container's PID namespace
    # @return [Integer]
    def ct_pid
      nspid[1]
    end

    # Return container pool and id as a tuple or nil
    # @return [Array, nil]
    def ct_id
      cache(:ct_id) do
        volatile do
          File.open(File.join(path, 'cgroup'), 'r') do |f|
            # It's not enough to check the first cgroup, it can happen that
            # the process remains only in some cgroups that belong to
            # the container, e.g. on an incorrect shutdown.
            f.each_line do |line|
              _id, _subsys, path = line.split(':')

              next if /^\/osctl\/pool\.([^\/]+)/ !~ path
              pool = $1

              next if /ct\.([^\/]+)\/user\-owned(\/|$)/ !~ path
              ctid = $1

              return [pool, ctid]
            end
          end

          nil
        end
      end
    end

    # @return [Integer, nil]
    def ct_ruid
      uns_host_to_ns('uid', ruid)
    end

    # @return [Integer, nil]
    def ct_rgid
      uns_host_to_ns('gid', rgid)
    end

    # @return [Integer, nil]
    def ct_euid
      uns_host_to_ns('uid', euid)
    end

    # @return [Integer, nil]
    def ct_egid
      uns_host_to_ns('gid', egid)
    end

    # Read /proc/<pid>/cmdline
    # @return [String]
    def cmdline
      volatile { File.read(File.join(path, 'cmdline')).gsub("\0", " ").strip }
    end

    # Flush cache and read fresh information from `/proc`
    def flush
      @cache.clear
      @id_maps.clear
    end

    protected
    attr_reader :path

    def parse_stat
      File.open(File.join(path, 'stat'), 'r') do |f|
        line = f.readline
        fields = line[line.rindex(')') + 1..-1].split

        # The third field in /proc/<pid>/stat (State) is the first in here, i.e.
        # substract 3 from field index documented in man proc to get
        # the appropriate field
        @state = fields[0]
        @ppid = fields[1].to_i
        @pgrp = fields[2].to_i
        @user_time = fields[11].to_i / TICS_PER_SECOND
        @sys_time = fields[12].to_i / TICS_PER_SECOND
        @nice = fields[16].to_i
        @num_threads = fields[17].to_i
        @start_time = self.class.system_start_time + (fields[19].to_i / TICS_PER_SECOND)
        @vmsize = fields[20].to_i
        @rss = fields[21].to_i
      end
    end

    def parse_status
      File.open(File.join(path, 'status'), 'r') do |f|
        f.each_line do |line|
          parts = line.split(':')
          next if parts.count != 2

          k = parts[0].strip
          v = parts[1].strip

          case k
          when 'NSpid'
            @nspid = v.split.map(&:to_i)

          when 'Uid'
            @ruid, @euid, @svuid, @fsuid = v.split.map(&:to_i)

          when 'Gid'
            @rgid, @egid, @svgid, @fsgid = v.split.map(&:to_i)

          when 'Name'
            @name = v
          end
        end
      end
    end

    def uns_host_to_ns(type, host_id)
      id_map(type).host_to_ns(host_id)
    end

    def id_map(type)
      @id_maps[type] ||= parse_id_map(type)
    end

    def parse_id_map(type)
      volatile do
        id_map = OsCtl::Lib::IdMap.new

        File.open(File.join(path, "#{type}_map"), 'r') do |f|
          f.each_line do |line|
            id_map.add_from_string(line, separator: ' ')
          end
        end

        id_map
      end
    end

    def volatile
      yield
    rescue Errno::ENOENT
      raise Exceptions::OsProcessNotFound, pid
    end

    def cache(key)
      if @cache.has_key?(key)
        @cache[key]
      else
        @cache[key] = yield
      end
    end
  end
end
