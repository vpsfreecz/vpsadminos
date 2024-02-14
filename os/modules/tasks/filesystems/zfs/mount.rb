#!@ruby@/bin/ruby
require 'etc'
require 'json'
require 'open3'
require 'thread'

class Dataset
  attr_reader :pool, :name, :type, :base_name, :parent_name, :mountpoint, :level, :real_properties, :declarative_properties
  attr_accessor :error

  def initialize(pool, name, type)
    @pool = pool
    @name = name
    @type = type
    @mountpoint = nil
    @real_properties = {}
    @declarative_properties = {}

    if root?
      @base_name = name
      @parent_name = nil
    else
      parts = name.split('/')
      @base_name = parts.last
      @parent_name = parts[0..-2].join('/')
    end
  end

  def filesystem?
    type == 'filesystem'
  end

  def volume?
    type == 'volume'
  end

  def valid?
    if @error
      false
    elsif volume? && !declarative_properties.has_key?('volsize')
      @error = 'volsize must be set'
      false
    else
      true
    end
  end

  attr_writer :exist

  def exist?
    @exist || false
  end

  def mounted?
    real_properties['mounted'] == 'yes'
  end

  def mount?
    !mounted? && canmount == 'on' && !%w[legacy none].include?(mountpoint)
  end

  def configure?
    declarative_properties.any?
  end

  def canmount
    declarative_properties['canmount'] || real_properties['canmount']
  end

  def root?
    pool.name == name
  end

  def parent
    @parent_name && pool.datasets[@parent_name]
  end

  def resolve_mountpoint
    raise 'not a filesystem' unless filesystem?

    @mountpoint = declarative_properties['mountpoint'] \
                  || real_properties['mountpoint'] \
                  || find_mountpoint
    @level = File.absolute_path(mountpoint).count('/')
  end

  def find_mountpoint
    if parent
      if parent.filesystem?
        File.join(parent.mountpoint, base_name)
      else
        @error = 'parent is not a filesystem'
        nil
      end
    else
      @error = 'parent not found'
      nil
    end
  end
end

class DatasetList
  def initialize
    @list = []
    @index = {}
  end

  def <<(dataset)
    list << dataset
    index[dataset.name] = dataset
  end

  def [](name)
    index[name]
  end

  def exist?(name)
    index.has_key?(name)
  end

  def each(&)
    list.each(&)
  end

  include Enumerable

  def sorted_by_mountpoint
    list.sort do |a, b|
      if a.volume?
        1
      elsif b.volume?
        -1
      else
        a.mountpoint <=> b.mountpoint
      end
    end
  end

  def sorted_to_mount_groups
    sorted_list = sorted_by_mountpoint.select do |ds|
      !ds.exist? || ds.mount? || ds.configure?
    end

    i = 1
    groups = []
    volumes = take_if(sorted_list, &:volume?)

    loop do
      filesystems = take_if(sorted_list) { |ds| ds.level == i }
      groups << filesystems unless filesystems.empty?

      break if sorted_list.empty?

      i += 1
    end

    groups << volumes if volumes.any?
    groups
  end

  protected

  attr_reader :list, :index

  def take_if(arr)
    ret = []

    arr.delete_if do |item|
      del = yield(item)
      ret << item if del
      del
    end

    ret
  end
end

class Pool
  ZFS = 'zfs'.freeze

  def self.mount_all(pool, config)
    p = new(pool, config)
    p.mount_all
  end

  attr_reader :pool, :datasets
  alias name pool

  def initialize(pool, config)
    @pool = pool
    @datasets = DatasetList.new
    @config = JSON.parse(File.read(config)) if config

    list_existing_datasets
    list_declarative_datasets
  end

  def mount_all
    groups = datasets.sorted_to_mount_groups
    tp = ThreadPool.new
    @printer = ProgressPrinter.new(groups.inject(0) { |acc, v| acc += v.length })

    groups.each do |grp|
      grp.each do |ds|
        tp.add do
          printer.next

          if !ds.valid?
            printer << "#{ds.name} has invalid configuration: #{ds.error}"
          elsif ds.exist?
            if ds.configure?
              printer << "Configuring #{ds.name}"
              configure(ds)
            end

            if ds.mount?
              printer << "Mounting #{ds.name}"
              mount(ds)
            end
          else
            printer << "Creating #{ds.name}"
            create(ds)
          end
        end
      end

      tp.run
    end
  end

  def create(dataset)
    args = [ZFS, 'create']

    if dataset.configure?
      if dataset.volume?
        args << '-V' << dataset.declarative_properties['volsize']
      end

      dataset.declarative_properties.each do |k, v|
        next if dataset.volume? && k == 'volsize'
        next if v == 'inherit'

        args << '-o' << "#{k}=#{property_value(v)}"
      end
    end

    system(*args, dataset.name)
  end

  def configure(dataset)
    dataset.declarative_properties.each do |k, v|
      if v == 'inherit'
        system(ZFS, 'inherit', k, dataset.name)
      else
        system(ZFS, 'set', "#{k}=#{property_value(v)}", dataset.name)
      end
    end
  end

  def mount(dataset)
    system(ZFS, 'mount', dataset.name)
  end

  protected

  attr_reader :printer

  def list_existing_datasets
    current_ds = nil

    Open3.popen2(
      ZFS, 'get',
      '-Hrp',
      '-t', 'filesystem,volume',
      '-o', 'name,property,value',
      'type,canmount,mounted,mountpoint',
      pool
    ) do |_stdin, stdout, status_thread|
      stdout.each_line do |line|
        name, property, value = line.split

        if current_ds.nil? || current_ds.name != name
          if current_ds
            current_ds.resolve_mountpoint if current_ds.filesystem?
            datasets << current_ds
          end

          current_ds = Dataset.new(self, name, value)
          current_ds.exist = true
        else
          current_ds.real_properties[property] = value
        end
      end

      raise 'Unable to list filesystems' unless status_thread.value.success?
    end

    return unless current_ds

    current_ds.resolve_mountpoint if current_ds.filesystem?
    datasets << current_ds
  end

  def list_declarative_datasets
    return unless @config

    # Convert datasets into internal representation
    list = @config.map do |name, opts|
      full_name = File.join(pool, name)
      full_name.chop! while full_name.end_with?('/')

      if datasets.exist?(full_name)
        ds = datasets[full_name]

        if ds.type != opts['type']
          ds.error = "dataset is a #{ds.type}, configuration expects #{opts['type']}"
        end
      else
        ds = Dataset.new(self, full_name, opts['type'])
        datasets << ds
      end

      ds.declarative_properties.update(opts['properties'])
      ds
    end

    # Sort by name
    list.sort! { |a, b| a.name <=> b.name }

    # Fill-in missing parent datasets and resolve mountpoints
    list.each do |ds|
      with_parents(ds).each do |ds|
        ds.resolve_mountpoint if ds.filesystem?
      end
    end
  end

  def with_parents(dataset)
    ret = [dataset]
    child = dataset

    until child.root? || child.parent
      parent = Dataset.new(self, child.parent_name, 'filesystem')
      datasets << parent
      ret << parent
      child = parent
    end

    ret.reverse!
  end

  def property_value(v)
    if v.is_a?(Hash)
      v['content']
    else
      v
    end
  end

  def system(*args)
    printer << "> #{File.basename(args[0])} #{args[1..].join(' ')}"
    Kernel.system(*args)
  end
end

class ThreadPool
  def initialize(threads = nil)
    @threads = threads || Etc.nprocessors
    @threads = 1 if @threads < 1
    @queue = Queue.new
  end

  def add(&block)
    queue << block
  end

  def run
    (1..threads).map do
      Thread.new { work }
    end.each(&:join)
  end

  protected

  attr_reader :threads, :queue

  def work
    loop do
      begin
        block = queue.pop(true)
      rescue ThreadError
        return
      end

      block.call
    end
  end
end

class ProgressPrinter
  attr_reader :total

  def initialize(n)
    @total = n
    @index = 1
    @mutex = Mutex.new
  end

  def <<(str)
    print(str)
  end

  def print(str)
    i = Thread.current[:progress_printer]

    @mutex.synchronize do
      puts "[#{i}/#{total}] #{str}"
    end
  end

  def next
    @mutex.synchronize do
      ret = index
      Thread.current[:progress_printer] = ret
      @index += 1
      ret
    end
  end

  protected

  attr_reader :mutex, :index
end

if ARGV.count < 1
  warn 'Usage: $0 <pool> [json datasets]'
  exit(false)
elsif Process.uid != 0
  warn 'Must be run as root'
  exit(false)
end

Pool.mount_all(ARGV[0], ARGV[1])
