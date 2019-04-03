#!@ruby@/bin/ruby
require 'json'
require 'open3'

class Dataset
  attr_reader :pool, :name, :type, :base_name, :parent_name, :mountpoint
  attr_reader :real_properties, :declarative_properties
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

  def exist=(exist)
    @exist = exist
  end

  def exist?
    @exist || false
  end

  def mounted?
    real_properties['mounted'] == 'yes'
  end

  def mount?
    !mounted? && canmount == 'on' && mountpoint != 'legacy'
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
    fail 'not a filesystem' unless filesystem?
    @mountpoint = declarative_properties['mountpoint'] \
                  || real_properties['mountpoint'] \
                  || find_mountpoint
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

  def each(&block)
    list.each(&block)
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

  protected
  attr_reader :list, :index
end

class Pool
  def self.mount_all(pool, config)
    p = new(pool, config)
    p.mount_all
  end

  attr_reader :pool, :datasets
  alias_method :name, :pool

  def initialize(pool, config)
    @pool = pool
    @datasets = DatasetList.new
    @config = JSON.parse(File.read(config)) if config

    list_existing_datasets
    list_declarative_datasets
  end

  def mount_all
    list = datasets.sorted_by_mountpoint.select do |ds|
      !ds.exist? || ds.mount? || ds.configure?
    end

    each_with_progress(list) do |ds|
      if !ds.valid?
        print "#{ds.name} has invalid configuration: #{ds.error}"
      elsif ds.exist?
        if ds.configure?
          print "Configuring #{ds.name}"
          configure(ds)
        end

        if ds.mount?
          print "Mounting #{ds.name}"
          mount(ds)
        end
      else
        print "Creating #{ds.name}"
        create(ds)
      end
    end
  end

  def create(dataset)
    args = ['zfs', 'create']

    if dataset.configure?
      if dataset.volume?
        args << '-V' << dataset.declarative_properties['volsize']
      end

      dataset.declarative_properties.each do |k, v|
        next if dataset.volume? && k == 'volsize'
        next if v == 'inherit'
        args << '-o' << "#{k}=#{v}"
      end
    end

    system(*args, dataset.name)
  end

  def configure(dataset)
    dataset.declarative_properties.each do |k, v|
      if v == 'inherit'
        system('zfs', 'inherit', k, dataset.name)
      else
        system('zfs', 'set', "#{k}=#{v}", dataset.name)
      end
    end
  end

  def mount(dataset)
    system('zfs', 'mount', dataset.name)
  end

  protected
  def list_existing_datasets
    current_ds = nil

    Open3.popen2(
      'zfs', 'get',
      '-Hrp',
      '-t', 'filesystem,volume',
      '-o', 'name,property,value',
      'type,canmount,mounted,mountpoint',
      pool
    ) do |stdin, stdout, status_thread|
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

      fail 'Unable to list filesystems' unless status_thread.value.success?
    end

    if current_ds
      current_ds.resolve_mountpoint if current_ds.filesystem?
      datasets << current_ds
    end
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
    list.sort! { |a,b| a.name <=> b.name }

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

    until child.root? || child.parent do
      parent = Dataset.new(self, child.parent_name, 'filesystem')
      datasets << parent
      ret << parent
      child = parent
    end

    ret.reverse!
  end

  def each_with_progress(array)
    @progress_cnt = array.length

    array.each_with_index do |v, i|
      @progress_i = i+1
      yield(v)
    end

    @progress_cnt = @progress_i = nil
  end

  def print(str)
    if @progress_cnt
      puts "[#{@progress_i}/#{@progress_cnt}] #{str}"
    else
      puts str
    end
  end

  def system(*args)
    print "> #{args.join(' ')}"
    Kernel.system(*args)
  end
end

if ARGV.count < 1
  warn "Usage: $0 <pool> [json datasets]"
  exit(false)
elsif Process.uid != 0
  warn "Must be run as root"
  exit(false)
end

Pool.mount_all(ARGV[0], ARGV[1])
