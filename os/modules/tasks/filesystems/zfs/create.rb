#!@ruby@/bin/ruby
require 'json'
require 'open3'

class Pool
  def self.create(pool, config_path)
    p = new(pool, config_path)
    p.create
  end

  attr_reader :pool, :config

  def initialize(pool, config_path)
    @pool = pool
    @config = JSON.parse(File.read(config_path))
  end

  def create
    unless force?
      preview
      confirm
    end

    do_create
  end

  protected

  def preview
    puts "WARNING: this program creates zpool #{pool} and may destroy existing"
    puts 'data on configured disks in the process. Use at own risk!'
    puts

    if wipe?
      puts 'Disks to wipe:'
      puts "  #{config['wipe'].join(' ')}"
      puts
    end

    if partition?
      puts 'Disks to partition:'
      puts "  #{config['partition'].keys.join(' ')}"
      puts
    end

    puts 'zpool to create:'
    puts '  zpool create ' +
         config['properties'].map { |k, v| "-o \"#{k}=#{v}\"" }.join(' ') +
         " #{pool} #{format_layout.join(' ')}"

    if has_spare?
      puts "  zpool add #{pool} spare #{config['spare'].join(' ')}"
    end

    if has_log?
      puts "  zpool add #{pool} log #{format_log.join(' ')}"
    end

    if has_cache?
      puts "  zpool add #{pool} cache #{config['cache'].join(' ')}"
    end

    puts
  end

  def confirm
    $stdout.write "Write uppercase 'yes' to confinue: "
    $stdout.flush

    return unless $stdin.readline.strip != 'YES'

    puts 'Aborting'
    exit(false)
  end

  def do_create
    if wipe?
      puts 'Wiping disks'
      do_wipe
    end

    if partition?
      puts 'Partitioning disks'
      do_partition
    end

    puts 'Creating the pool'
    system(
      'zpool', 'create',
      *config['properties'].map { |k, v| ['-o', "#{k}=#{v}"] }.flatten,
      pool,
      *format_layout
    )

    if has_spare?
      puts 'Adding spares'
      system('zpool', 'add', pool, 'spare', *config['spare'])
    end

    if has_log?
      puts 'Adding logs'
      system('zpool', 'add', pool, 'log', *format_log)
    end

    return unless has_cache?

    puts 'Adding caches'
    system('zpool', 'add', pool, 'cache', *config['cache'])
  end

  def do_wipe
    find_devices(config['wipe']).each do |dev|
      raise "Device #{dev} not found" unless File.exist?(dev)

      File.open(dev, 'wb') do |f|
        f.syswrite("\0" * 4096)
        f.sysseek(-4096, IO::SEEK_END)
        f.syswrite("\0" * 4096)
      end
    end
  end

  def do_partition
    config['partition'].each do |dev, partitions|
      dev_path = find_device(dev)

      Open3.popen2('sfdisk', '-q', dev_path) do |stdin, stdout, status_thread|
        partitions.each do |part, opts|
          part_index = part[1..]

          fields = { type: opts['type'] }
          fields[:size] = opts['sizeGB'] * 2048 * 1024 if opts['sizeGB']

          stdin.puts "#{part_index}:#{fields.map { |k, v| "#{k}=#{v}" }.join(',')}"
        end

        stdin.close
        stdout.read
        raise "Unable to partition #{dev_path}" unless status_thread.value.success?
      end
    end
  end

  def partition_size(size_gb)
    if size_gb
      "size=#{size_gb * 2048 * 1024},"
    else
      ''
    end
  end

  def has_log?
    config['log'].any?
  end

  def has_cache?
    config['cache'].any?
  end

  def has_spare?
    config['spare'].any?
  end

  def force?
    ARGV[0] == '--force'
  end

  def wipe?
    config['wipe'].any?
  end

  def partition?
    config['partition'].any?
  end

  def find_devices(devices)
    devices.map do |dev|
      find_device(dev)
    end
  end

  def find_device(device)
    if device.start_with?('/')
      device
    else
      File.join('/dev', device)
    end
  end

  def format_layout
    sort_layout.map do |vdev|
      if vdev['type'] == 'stripe'
        vdev['devices']
      else
        [vdev['type']] + vdev['devices']
      end
    end.flatten
  end

  def format_log
    sort_log.map do |vdev|
      if vdev['mirror']
        ['mirror'] + vdev['devices']
      else
        vdev['devices']
      end
    end.flatten
  end

  def sort_layout
    head = []
    tail = []

    config['layout'].each do |vdev|
      if vdev['type'] == 'stripe'
        head << vdev
      else
        tail << vdev
      end
    end

    head + tail
  end

  def sort_log
    head = []
    tail = []

    config['log'].each do |vdev|
      if vdev['mirror']
        tail << vdev
      else
        head << vdev
      end
    end

    head + tail
  end

  def system(*args)
    return if Kernel.system(*args)

    raise "Command #{args.join(' ')} failed"
  end
end

if Process.uid != 0
  warn 'Must be run as root'
  exit(false)
end

Pool.create(
  '@poolName@',
  '@poolConfig@'
)
