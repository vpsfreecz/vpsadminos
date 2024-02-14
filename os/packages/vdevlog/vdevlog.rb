#!@ruby@/bin/ruby
require 'json'
require 'optparse'
require 'syslog/logger'

module VdevLog
  class LogEntry
    # @return [Time]
    attr_reader :time

    # @return [Integer]
    attr_reader :guid

    # @return [Integer]
    attr_reader :read

    # @return [Integer]
    attr_reader :write

    # @return [Integer]
    attr_reader :checksum

    # @return [ZioRequest, nil]
    attr_reader :zio_request

    # @return [LogEntry]
    def self.from_state(hash)
      new(
        Time.at(hash['time']),
        hash['guid'],
        hash['read'],
        hash['write'],
        hash['checksum'],
        hash['zio_request'] && ZioRequest.from_state(hash['zio_request'])
      )
    end

    # @param time [Time]
    # @param guid [Integer]
    # @param read [Integer]
    # @param write [Integer]
    # @param checksum [Integer]
    # @param zio_request [ZioRequest, nil]
    def initialize(time, guid, read, write, checksum, zio_request)
      @time = time
      @guid = guid
      @read = read
      @write = write
      @checksum = checksum
      @zio_request = zio_request
    end

    def dump
      {
        'time' => time.to_i,
        'guid' => guid,
        'read' => read,
        'write' => write,
        'checksum' => checksum,
        'zio_request' => zio_request && zio_request.dump
      }
    end
  end

  class LastErrors
    # @return [LastErrors]
    def self.from_state(hash)
      new(
        read: hash['read'],
        write: hash['write'],
        checksum: hash['checksum']
      )
    end

    # @return [Integer]
    attr_reader :read

    # @return [Integer]
    attr_reader :write

    # @return [Integer]
    attr_reader :checksum

    # @param read [Integer]
    # @param write [Integer]
    # @param checksum [Integer]
    def initialize(read: 0, write: 0, checksum: 0)
      @read = read
      @write = write
      @checksum = checksum
    end

    # @param errors [Errors]
    def set(errors)
      @read = errors.read
      @write = errors.write
      @checksum = errors.checksum
    end

    def dump
      {
        'read' => read,
        'write' => write,
        'checksum' => checksum
      }
    end
  end

  class Errors
    # @return [Errors]
    def self.from_state(hash)
      new(
        read: hash['read'],
        write: hash['write'],
        checksum: hash['checksum'],
        last: hash['last'] && LastErrors.from_state(hash['last'])
      )
    end

    # @return [Integer]
    attr_reader :read

    # @return [Integer]
    attr_reader :write

    # @return [Integer]
    attr_reader :checksum

    # @param read [Integer]
    # @param write [Integer]
    # @param checksum [Integer]
    # @param last [LastErrors, nil]
    def initialize(read: 0, write: 0, checksum: 0, last: nil)
      @read = read
      @write = write
      @checksum = checksum
      @last = last || LastErrors.new
    end

    def any?
      @read > 0 || @write > 0 || @checksum > 0
    end

    # @param errors [Errors]
    # @return [Array<Integer, Integer, Integer] read, write, checksum
    def add(errors)
      diffs =
        if errors.read < last.read \
           || errors.write < last.write \
           || errors.checksum < last.checksum
          [errors.read, errors.write, errors.checksum]
        else
          [
            errors.read - last.read,
            errors.write - last.write,
            errors.checksum - last.checksum
          ]
        end

      read_diff, write_diff, checksum_diff = diffs

      @read += read_diff
      @write += write_diff
      @checksum += checksum_diff

      @last.set(errors)
      diffs
    end

    def dump
      {
        'read' => read,
        'write' => write,
        'checksum' => checksum,
        'last' => last.dump
      }
    end

    protected

    attr_reader :last
  end

  class ZioRequest
    ATTRS = %i[
      objset
      object
      level
      priority
      blkid
      err
      offset
      size
      flags
      stage
      pipeline
      delay
      timestamp
      delta
    ].freeze

    def self.from_state(hash)
      kwargs = {}

      ATTRS.each do |k|
        v = hash[k.to_s]
        kwargs[k] = v if v
      end

      new(**kwargs)
    end

    def self.from_env(env)
      kwargs = {}

      ATTRS.each do |k|
        v = env["ZEVENT_ZIO_#{k.to_s.upcase}"]
        kwargs[k] = v.to_i if v
      end

      new(**kwargs)
    end

    # @return [Integer]
    attr_reader :objset

    # @return [Integer]
    attr_reader :object

    # @return [Integer]
    attr_reader :level

    # @return [Integer]
    attr_reader :priority

    # @return [Integer]
    attr_reader :blkid

    # @return [Integer]
    attr_reader :err

    # @return [Integer]
    attr_reader :offset

    # @return [Integer]
    attr_reader :size

    # @return [Integer]
    attr_reader :flags

    # @return [Integer]
    attr_reader :stage

    # @return [Integer]
    attr_reader :pipeline

    # @return [Integer]
    attr_reader :delay

    # @return [Integer]
    attr_reader :timestamp

    # @return [Integer]
    attr_reader :delta

    def initialize(**kwargs)
      ATTRS.each do |k|
        v = kwargs[k]
        instance_variable_set(:"@#{k}", v) if v
      end
    end

    def dump
      ret = {}

      ATTRS.each do |k|
        v = send(k)
        ret[k.to_s] = v if v
      end

      ret
    end
  end

  class ZEvent
    # @return [ZEvent]
    def self.parse(env)
      klass =
        case env['ZEVENT_CLASS']
        when 'ereport.fs.zfs.io'
          IOZEvent
        else
          raise "unsupported zevent class #{env['ZEVENT_CLASS'].inspect}"
        end

      klass.new(env)
    end

    # @return [Integer]
    attr_reader :eid

    # @return [String]
    attr_reader :event_class

    # @return [Time]
    attr_reader :time

    # @return [String]
    attr_reader :pool

    # @param env [ENV, Hash]
    def initialize(env)
      parse_env(env)
    end

    protected

    def parse_env(env)
      @eid = env['ZEVENT_EID'].to_i
      @event_class = env['ZEVENT_CLASS']
      @time = Time.at(env['ZEVENT_TIME_SECS'].to_i, env['ZEVENT_TIME_NSECS'].to_i, :nsec)
      @pool = env['ZEVENT_POOL']
    end
  end

  class IOZEvent < ZEvent
    # @return [Integer]
    attr_reader :vdev_guid

    # @return [String]
    attr_reader :vdev_path

    # @return [String]
    attr_reader :vdev_type

    # @return [Errors]
    attr_reader :vdev_errors

    # @return [ZioRequest]
    attr_reader :zio_request

    protected

    def parse_env(env)
      super
      @vdev_guid = env['ZEVENT_VDEV_GUID'].to_i(16)
      @vdev_path = env['ZEVENT_VDEV_PATH']
      @vdev_type = env['ZEVENT_VDEV_TYPE']
      @vdev_errors = Errors.new(
        read: env['ZEVENT_VDEV_READ_ERRORS'].to_i,
        write: env['ZEVENT_VDEV_WRITE_ERRORS'].to_i,
        checksum: env['ZEVENT_VDEV_CKSUM_ERRORS'].to_i
      )
      @zio_request = ZioRequest.from_env(env)
    end
  end

  class Vdev
    # @return [Vdev]
    def self.from_state(hash)
      new(
        hash['guid'],
        ids: hash['ids'],
        paths: hash['paths'],
        state: hash['state'],
        errors: Errors.from_state(hash['errors'])
      )
    end

    # @return [Integer]
    attr_reader :guid

    # @return [Array<String>]
    attr_accessor :ids

    # @return [Array<String>]
    attr_accessor :paths

    # @return [Errors]
    attr_reader :errors

    # @return [String]
    attr_accessor :state

    # @param guid [Integer]
    # @param ids [Array<String>]
    # @param paths [Array<String>]
    # @param state [String]
    # @param errors [Errors, nil]
    def initialize(guid, ids:, paths:, state: 'online', errors: nil)
      @guid = guid
      @ids = ids
      @paths = paths
      @state = state
      @errors = errors || Errors.new
    end

    def to_json(*, **)
      {
        'guid' => guid,
        'ids' => ids,
        'paths' => paths,
        'state' => state,
        'errors' => errors.dump
      }.to_json(*, **)
    end
  end

  class State
    # Read and update state
    # @param logger [Syslog::Logger]
    # @param pool [String]
    # @yieldparam [State]
    def self.update(logger, pool)
      state = new(logger, pool)
      state.lock do
        state.open
        yield(state)
        state.save
      end
      nil
    end

    # Read state
    # @param logger [Syslog::Logger]
    # @param pool [String]
    # @yieldparam [State]
    def self.read(logger, pool)
      state = new(logger, pool)
      state.lock(type: File::LOCK_SH) do
        state.open
        yield(state)
      end
      nil
    end

    # @return [Array<Vdev>]
    attr_reader :vdevs

    # @return [Array<LogEntry>]
    attr_reader :log

    # @param logger [Syslog::Logger]
    # @param pool [String]
    def initialize(logger, pool)
      mountpoint, mounted = `zfs get -Hp -o value mountpoint,mounted #{pool}`.strip.split

      if $?.exitstatus != 0
        raise "zfs get failed with exit status #{$?.exitstatus}"
      end

      raise "pool #{pool.inspect} is not mounted" if mounted != 'yes'

      @logger = logger
      @pool = pool
      @state_dir = File.join(mountpoint, '.vdevlog')
      @state_file = File.join(@state_dir, 'state.json')
      @prom_file = File.join(@state_dir, 'state.prom')
      @lock_file = File.join(@state_dir, 'state.lock')
      @vdevs = []
      @log = []
    end

    def lock(type: File::LOCK_EX)
      make_state_dir

      File.open(@lock_file, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(type)
        yield(self)
      end
    end

    def open
      begin
        s = File.read(@state_file)
      rescue Errno::ENOENT
        return
      end

      data = JSON.parse(s)
      @vdevs = data.fetch('vdevs', []).map { |v| Vdev.from_state(v) }
      @log = data.fetch('log', []).map { |v| LogEntry.from_state(v) }
    end

    def save
      make_state_dir
      save_state
      gen_prom_file
    end

    # @param event [ZEvent]
    def <<(event)
      case event
      when IOZEvent
        add_io_errors(event)
      else
        @logger.info("Ignoring event eid=#{event.eid} class=#{event.event_class}")
      end
    end

    # @param dir [String] metrics directory
    def install_prom_file(dir)
      return unless Dir.exist?(dir)

      target = File.join(dir, "vdevlog-#{@pool}.prom")

      begin
        File.unlink(target)
      rescue Errno::ENOENT
      end

      File.symlink(@prom_file, target)
    end

    protected

    def add_io_errors(event)
      vdev = @vdevs.detect { |v| v.guid == event.vdev_guid }

      if vdev.nil?
        @logger.warn(
          "Unable to log IO errors from eid=#{event.eid} on vdev pool=#{@pool} " \
          "guid=#{event.vdev_guid} path=#{event.vdev_path}: vdev not found in state file"
        )
        return
      end

      read, write, checksum = vdev.errors.add(event.vdev_errors)
      @logger.info(
        "Recording IO errors from eid=#{event.eid} on vdev pool=#{@pool} guid=#{vdev.guid} " \
        "ids=#{vdev.ids.join(',')} read=#{read} write=#{write} checksum=#{checksum}"
      )
      log << LogEntry.new(event.time, vdev.guid, read, write, checksum, event.zio_request)
      nil
    end

    def save_state
      replace_file(@state_file) do |f|
        f.write({
          'vdevs' => @vdevs,
          'log' => @log.map(&:dump)
        }.to_json)
      end
    end

    def gen_prom_file
      replace_file(@prom_file) do |f|
        %i[read write checksum].each do |err|
          metric = "zfs_vdevlog_vdev_#{err}_errors"
          f.puts("# HELP #{metric} Total number of #{err} errors")
          f.puts("# TYPE #{metric} gauge")

          @vdevs.each do |vdev|
            labels = {
              pool: @pool,
              vdev_guid: vdev.guid,
              vdev_id: vdev.ids.first,
              vdev_state: vdev.state
            }
            f.puts("#{metric}{#{labels.map { |k, v| "#{k}=\"#{v}\"" }.join(',')}} #{vdev.errors.send(err)}")
          end
        end
      end
    end

    def replace_file(path, &)
      tmp = "#{path}.new"
      File.open(tmp, 'w', &)
      File.rename(tmp, path)
    end

    def make_state_dir
      Dir.mkdir(@state_dir)
    rescue Errno::EEXIST
    end
  end

  class PoolStatus
    Disk = Struct.new(:guid, :path, :whole_disk, :state, :errors, :ids, :paths) do
      def initialize
        self.ids = []
        self.paths = []
      end
    end

    # @param pools [Hash<String, Array<Disk>>]
    attr_reader :pools

    # @param pools [Array<String>]
    def initialize(pools: [])
      @pools = list_vdevs(pools)

      add_vdev_status(@pools)

      @pools.each_value do |disks|
        find_disk_symlinks(disks)
      end
    end

    protected

    def list_vdevs(read_pools)
      # zdb will list all zpools and their vdevs. One known caveat is that it
      # does not include cache devices. Those are thus not tracked by vdevlog.
      info = `zdb`.strip

      if $?.exitstatus != 0
        raise "zdb exited with #{$?.exitstatus}"
      end

      pools = {}
      vdevs = []

      cur_pool = nil
      skip_pool = false
      in_vdev = false
      cur_vdev = nil

      info.each_line do |line|
        stripped = line.strip

        # Pool section
        if /^([^\s])+:$/ =~ line
          if cur_pool
            vdevs << cur_vdev if cur_vdev
            pools[cur_pool] = vdevs
          end

          # Remove ending colon
          pool_name = stripped[0..-2]

          skip_pool = read_pools.any? && !read_pools.include?(pool_name)
          cur_pool = skip_pool ? nil : pool_name
          vdevs = []
          in_vdev = false
          cur_vdev = nil

          next
        end

        next if cur_pool.nil? || skip_pool

        colon = stripped.index(':')
        next if colon.nil?

        k = stripped[0..colon - 1]
        v = stripped[colon + 2..]

        next if v.nil?

        # Remove quotes
        if v.start_with?("'") && v.end_with?("'")
          v = v[1..-2]
        end

        # Parse vdev properties
        if k.start_with?('children[')
          in_vdev = false

        elsif k == 'type'
          vdevs << cur_vdev if cur_vdev

          if v == 'disk'
            in_vdev = true
            cur_vdev = Disk.new
          else
            in_vdev = false
            cur_vdev = nil
          end

        elsif in_vdev && k == 'guid'
          cur_vdev.guid = v.to_i

        elsif in_vdev && k == 'path'
          cur_vdev.path = v

        elsif in_vdev && k == 'whole_disk'
          cur_vdev.whole_disk = v == '1'
        end
      end

      vdevs << cur_vdev if cur_vdev
      pools[cur_pool] = vdevs if cur_pool

      pools
    end

    def add_vdev_status(pools)
      if pools.empty?
        raise ArgumentError, 'expected a non-empty hash of pools'
      end

      status = `zpool status -g #{pools.keys.join(' ')}`

      if $?.exitstatus != 0
        raise "zpool status exited with #{$?.exitstatus}"
      end

      cur_pool = nil
      in_config = false

      status.each_line do |line|
        stripped = line.strip

        if stripped.start_with?('pool:')
          cur_pool = stripped[5..].strip
        elsif cur_pool && stripped.start_with?('config:')
          in_config = true
        elsif cur_pool && in_config
          guid, state, read, write, checksum, = stripped.split
          next unless /^\d+$/ =~ guid

          guid_i = guid.to_i

          disk = pools[cur_pool].detect { |v| v.guid == guid_i }
          next if disk.nil?

          disk.state = state.downcase
          disk.errors = Errors.new(
            read: read.to_i,
            write: write.to_i,
            checksum: checksum.to_i
          )
        end
      end
    end

    def find_disk_symlinks(disks)
      disks.each do |disk|
        begin
          # This is always a partition name, even if ZFS uses the whole disk
          dev_path = File.realpath(disk.path)
        rescue Errno::ENOENT
          # The disk might no longer be in the system
          next
        end

        short_name = File.basename(dev_path)

        lookup_name =
          if disk.whole_disk
            File.readlink(File.join('/sys/class/block', short_name)).split('/')[-2]
          else
            short_name
          end

        symlinks = `udevadm info -q symlink --path=/sys/class/block/#{lookup_name}`.strip.split

        if $?.exitstatus != 0
          raise "udevadm on #{lookup_name.inspect} failed with exit status #{$?.exitstatus}"
        end

        symlinks.each do |symlink|
          _, type, v = symlink.split('/')

          case type
          when 'by-id'
            disk.ids << v
          when 'by-path'
            disk.paths << v
          end
        end
      end
    end
  end

  class Cli
    # @param env [ENV, Hash]
    # @param args [Array<String>]
    def initialize(env, args)
      @env = env
      @args = args
      @logger = Syslog::Logger.new('vdevlog')
    end

    def run
      parse_opts
      send(@options[:action])
    rescue Exception => e
      if @options[:action] == :run_zedlet
        @logger.fatal("Exception occurred: #{e.message} (#{e.class})")
      end

      raise
    end

    protected

    def parse_opts
      @options = {
        action: :run_zedlet,
        verbose: 0,
        record: false,
        clear: true
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [ls|update [options]]"

        opts.on('-v', '--verbose', 'Show error log and ZIO requests') do
          @options[:verbose] += 1
        end

        opts.on('-i', '--install DIR', 'Install vdevlog metrics into node_exporter') do |dir|
          @options[:install] = dir
        end

        opts.on('-r', '--record', 'Record errors from zpool status') do
          @options[:record] = true
        end

        opts.on('-c', '--[no-]clear', 'Clear recorded errors from zpool status') do |v|
          @options[:clear] = v
        end

        opts.on('-h', '--help', 'Show this message and exit') do
          puts opts
          exit
        end
      end

      parser.parse!(@args)

      case @args[0]
      when 'ls'
        @options[:action] = :run_list
        @options[:pools] = @args[1..] || []
      when 'update'
        @options[:action] = :run_update
        @options[:pools] = @args[1..] || []
      when nil
        # run_zedlet
      else
        warn "Unknown command #{@args[0].inspect}"
        warn parser
        exit(false)
      end

      return unless @options[:action] == :run_zedlet && !@env['ZEVENT_CLASS']

      warn 'Specify command or invoke by ZED'
      warn parser
      exit(false)
    end

    def run_list
      header_fmt = '%-10s %26s %9s %9s %9s  '
      row_vdev_fmt = '%-10s %26d %9d %9d %9d  '
      row_log_fmt = '%-10s %26s %9d %9d %9d  '
      row_log_nozio_fmt = row_log_fmt.dup

      if @options[:verbose] > 1
        header_fmt << '%30s %8s %18s %5s %10s %s'
        row_vdev_fmt << '%30s'
        row_log_fmt << '%30s %8d %18d %5d %10s %s'
        row_log_nozio_fmt << '%30s'
      else
        header_fmt << '%s'
        row_vdev_fmt << '%s'
        row_log_fmt << '%s'
        row_log_nozio_fmt << '%s'
      end

      puts format(
        header_fmt,
        'POOL',
        'GUID',
        'READ',
        'WRITE',
        'CHECKSUM',
        @options[:verbose] > 0 ? 'ID/TIME' : 'ID',
        *(@options[:verbose] > 1 ? %w[SIZE OFFSET ERR FLAGS BOOKMARK] : [])
      )

      each_pool do |pool|
        State.read(@logger, pool) do |state|
          log_per_vdev =
            state.log.each_with_object({}) do |entry, acc|
              acc[entry.guid] ||= []
              acc[entry.guid] << entry
            end

          state.vdevs.each do |vdev|
            next unless vdev.errors.any?

            puts format(
              row_vdev_fmt,
              pool,
              vdev.guid,
              vdev.errors.read,
              vdev.errors.write,
              vdev.errors.checksum,
              vdev.ids.first
            )

            next unless @options[:verbose] > 0

            log_per_vdev.fetch(vdev.guid, []).each do |entry|
              zio = entry.zio_request

              puts format(
                zio ? row_log_fmt : row_log_nozio_fmt,
                '',
                '',
                entry.read,
                entry.write,
                entry.checksum,
                entry.time.to_s,
                *(if zio && @options[:verbose] > 1
                    [
                      zio.size,
                      zio.offset,
                      zio.err,
                      "0x#{zio.flags.to_s(16)}",
                      zio.objset ? [zio.objset, zio.object, zio.level, zio.blkid].join(':') : '-'
                    ]
                  else
                    []
                  end)
              )
            end
          end
        end
      end
    end

    def run_update
      pool_status = PoolStatus.new(pools: @options[:pools])

      pool_status.pools.each do |pool, disks|
        State.update(@logger, pool) do |state|
          t = Time.now

          # Add newly discovered vdevs and update vdev state
          disks.each do |disk|
            vdev = state.vdevs.detect { |v| v.guid == disk.guid }

            if vdev.nil?
              vdev = Vdev.new(
                disk.guid,
                ids: disk.ids,
                paths: disk.paths,
                state: disk.state
              )

              state.vdevs << vdev
            else
              vdev.state = disk.state
              vdev.ids = disk.ids if disk.ids.any?
              vdev.paths = disk.paths if disk.paths.any?
            end

            if @options[:record] && disk.errors.any?
              read, write, checksum = vdev.errors.add(disk.errors)
              state.log << LogEntry.new(t, vdev.guid, read, write, checksum, nil)
            end
          end

          # Remove obsoleted vdevs
          state.vdevs.delete_if do |vdev|
            if disks.detect { |v| v.guid == vdev.guid }.nil?
              @logger.info(
                "Removing obsolete vdev pool=#{pool} guid=#{vdev.guid} " \
                "ids=#{vdev.ids.join(',')} read=#{vdev.errors.read} " \
                "write=#{vdev.errors.write} checksum=#{vdev.errors.checksum}"
              )
              true
            else
              false
            end
          end

          state.install_prom_file(@options[:install]) if @options[:install]
        end

        if @options[:record] && @options[:clear] && !Kernel.system('zpool', 'clear', pool)
          warn "Failed to clear zpool #{pool}"
        end
      end
    end

    def run_zedlet
      event = ZEvent.parse(@env)

      State.update(@logger, event.pool) do |state|
        state << event
      end
    end

    def each_pool(&)
      if @options[:pools].any?
        @options[:pools].each(&)
      else
        pools = `zpool list -H -o name`.strip.split

        if $?.exitstatus != 0
          raise "zpool list exited with #{$?.exitstatus}"
        end

        pools.each(&)
      end
    end
  end
end

log = VdevLog::Cli.new(ENV, ARGV)
log.run
