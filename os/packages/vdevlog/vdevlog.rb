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

    # @return [ZioRequest]
    attr_reader :zio_request

    # @return [LogEntry]
    def self.from_state(hash)
      new(
        Time.at(hash['time']),
        hash['guid'],
        hash['read'],
        hash['write'],
        hash['checksum'],
        ZioRequest.from_state(hash['zio_request']),
      )
    end

    # @param time [Time]
    # @param guid [Integer]
    # @param read [Integer]
    # @param write [Integer]
    # @param checksum [Integer]
    # @param zio_request [ZioRequest]
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
        'zio_request' => zio_request.dump,
      }
    end
  end

  class LastErrors
    # @return [LastErrors]
    def self.from_state(hash)
      new(
        read: hash['read'],
        write: hash['write'],
        checksum: hash['checksum'],
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
        'checksum' => checksum,
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
        last: hash['last'] && LastErrors.from_state(hash['last']),
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
            errors.checksum - last.checksum,
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
        'last' => last.dump,
      }
    end

    protected
    attr_reader :last
  end

  class ZioRequest
    ATTRS = %i(
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
    )

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
          fail "unsupported zevent class #{env['ZEVENT_CLASS'].inspect}"
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
        checksum: env['ZEVENT_VDEV_CKSUM_ERRORS'].to_i,
      )
      @zio_request = ZioRequest.from_env(env)
    end
  end

  class Vdev
    # @param guid [Integer]
    # @param dev_name [String]
    # @return [Vdev]
    def self.from_guid_and_dev_name(guid, dev_name)
      # ZED always reports partition names, even if the whole disk was given
      # to ZFS
      short_partition_name = File.basename(dev_name)
      short_disk_name = File.readlink(File.join('/sys/class/block', short_partition_name)).split('/')[-2]

      symlinks = `udevadm info -q symlink --path=/sys/block/#{short_disk_name}`.strip.split
      if $?.exitstatus != 0
        fail "udevadm failed with exit status #{$?.exitstatus}"
      end

      ids = symlinks.inject([]) do |acc, symlink|
        _, type, v = symlink.split('/')
        acc << v if type == 'by-id'
        acc
      end

      if ids.empty?
        fail "no id found for #{dev_name.inspect}"
      end

      Vdev.new(guid, ids)
    end

    # @return [Vdev]
    def self.from_state(hash)
      new(
        hash['guid'],
        hash['ids'],
        state: hash['state'],
        errors: Errors.from_state(hash['errors']),
      )
    end

    # @return [Integer]
    attr_reader :guid

    # @return [Array<String>]
    attr_reader :ids

    # @return [Errors]
    attr_reader :errors

    # @return [String]
    attr_accessor :state

    # @param guid [Integer]
    # @param ids [Array<String>]
    # @param state [String]
    # @param errors [Errors, nil]
    def initialize(guid, ids, state: 'online', errors: nil)
      @guid = guid
      @ids = ids
      @state = state
      @errors = errors || Errors.new
    end

    def to_json(*args, **kwargs)
      {
        'guid' => guid,
        'ids' => ids,
        'state' => state,
        'errors' => errors.dump,
      }.to_json(*args, **kwargs)
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
        fail "zfs get failed with exit status #{$?.exitstatus}"
      end

      fail "pool #{pool.inspect} is not mounted" if mounted != 'yes'

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

      File.open(@lock_file, File::RDWR|File::CREAT, 0600) do |f|
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
        vdev = Vdev.from_guid_and_dev_name(event.vdev_guid, event.vdev_path)
        @vdevs << vdev
      end

      read, write, checksum = vdev.errors.add(event.vdev_errors)
      @logger.info(
        "Recording IO errors from eid=#{event.eid} on vdev pool=#{@pool} guid=#{vdev.guid} "+
        "ids=#{vdev.ids.join(',')} read=#{read} write=#{write} checksum=#{checksum}"
      )
      log << LogEntry.new(event.time, vdev.guid, read, write, checksum, event.zio_request)
      nil
    end

    def save_state
      replace_file(@state_file) do |f|
        f.write({
          'vdevs' => @vdevs,
          'log' => @log.map(&:dump),
        }.to_json)
      end
    end

    def gen_prom_file
      replace_file(@prom_file) do |f|
        %i(read write checksum).each do |err|
          metric = "zfs_vdevlog_vdev_#{err}_errors"
          f.puts("# HELP #{metric} Total number of #{err} errors")
          f.puts("# TYPE #{metric} gauge")

          @vdevs.each do |vdev|
            labels = {
              pool: @pool,
              vdev_guid: vdev.guid,
              vdev_id: vdev.ids.first,
              vdev_state: vdev.state,
            }
            f.puts("#{metric}{#{labels.map { |k, v| "#{k}=\"#{v}\"" }.join(',')}} #{vdev.errors.send(err)}")
          end
        end
      end
    end

    def replace_file(path)
      tmp = "#{path}.new"
      File.open(tmp, 'w') { |f| yield(f) }
      File.rename(tmp, path)
    end

    def make_state_dir
      Dir.mkdir(@state_dir)
    rescue Errno::EEXIST
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
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options]"

        opts.on('-l', '--list [POOL]', 'List vdev errors') do |pool|
          @options[:action] = :run_list
          @options[:pool] = pool
        end

        opts.on('-v', '--verbose', 'Show error log') do
          @options[:verbose] = true
        end

        opts.on('-u', '--update [POOL]', 'Sync logged vdevs with zpool status') do |pool|
          @options[:action] = :run_update
          @options[:pool] = pool
        end

        opts.on('-i', '--install DIR', 'Install vdevlog metrics into node_exporter') do |dir|
          @options[:install] = dir
        end

        opts.on('-h', '--help', 'Show this message and exit') do
          puts opts
          exit
        end
      end

      parser.parse!(@args)

      if @options[:action] == :run_zedlet && !@env['ZEVENT_CLASS']
        warn 'Specify action or invoke by ZED'
        warn parser
        exit(false)
      end
    end

    def run_list
      puts sprintf(
        '%-10s %26s %9s %9s %9s  %s',
        'POOL',
        'GUID',
        'READ',
        'WRITE',
        'CHECKSUM',
        @options[:verbose] ? 'ID/TIME' : 'ID',
      )

      each_pool do |pool|
        State.read(@logger, pool) do |state|
          log_per_vdev =
            state.log.inject({}) do |acc, entry|
              acc[entry.guid] ||= []
              acc[entry.guid] << entry
              acc
            end

          state.vdevs.each do |vdev|
            puts sprintf(
              '%-10s %26d %9d %9d %9d  %s',
              pool,
              vdev.guid,
              vdev.errors.read,
              vdev.errors.write,
              vdev.errors.checksum,
              vdev.ids.first,
            )

            if @options[:verbose]
              log_per_vdev.fetch(vdev.guid, []).each do |entry|
                puts sprintf(
                  '%-10s %26s %9d %9d %9d  %s',
                  '',
                  '',
                  entry.read,
                  entry.write,
                  entry.checksum,
                  entry.time.to_s,
                )
              end
            end
          end
        end
      end
    end

    def run_update
      pool_guids = get_pool_vdev_guids((@options[:pool] || '').split(','))

      pool_guids.each do |pool, guid_states|
        State.update(@logger, pool) do |state|
          state.vdevs.delete_if do |vdev|
            if guid_states.has_key?(vdev.guid)
              vdev.state = guid_states[vdev.guid]
              false
            else
              @logger.info(
                "Removing obsolete vdev pool=#{pool} guid=#{vdev.guid} "+
                "ids=#{vdev.ids.join(',')} read=#{vdev.errors.read} "+
                "write=#{vdev.errors.write} checksum=#{vdev.errors.checksum}"
              )
              true
            end
          end

          state.install_prom_file(@options[:install]) if @options[:install]
        end
      end
    end

    def run_zedlet
      event = ZEvent.parse(@env)

      State.update(@logger, event.pool) do |state|
        state << event
      end
    end

    def each_pool(&block)
      if @options[:pool]
        @options[:pool].split(',').each(&block)
      else
        pools = `zpool list -H -o name`.strip.split

        if $?.exitstatus != 0
          fail "zpool list exited with #{$?.exitstatus}"
        end

        pools.each(&block)
      end
    end

    def get_pool_vdev_guids(pools = [])
      status = `zpool status -g #{pools.join(' ')}`
      if $?.exitstatus != 0
        fail "zpool status exited with #{$?.exitstatus}"
      end

      cur_pool = nil
      in_config = false
      guids = {}

      status.each_line do |line|
        stripped = line.strip

        if stripped.start_with?('pool:')
          cur_pool = stripped[5..-1].strip
          guids[cur_pool] = {}
        elsif cur_pool && stripped.start_with?('config:')
          in_config = true
        elsif cur_pool && in_config
          guid, state, _ = stripped.split
          guids[cur_pool][guid.to_i] = state.downcase if /^\d+$/ =~ guid
        end
      end

      guids
    end
  end
end

log = VdevLog::Cli.new(ENV, ARGV)
log.run