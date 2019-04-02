#!@ruby@/bin/ruby
require 'open3'

class Pool
  Dataset = Struct.new(:name, :mountpoint)

  def self.mount_all(pool)
    p = new(pool)
    p.mount_all
  end

  attr_reader :pool

  def initialize(pool)
    @pool = pool
  end

  def mount_all
    datasets = sorted_datasets_by_mountpoint
    cnt = datasets.count

    datasets.each_with_index do |ds, i|
      puts "[#{i+1}/#{cnt}] Mounting #{ds.name}"
      Kernel.system('zfs', 'mount', ds.name)
    end
  end

  protected
  def sorted_datasets_by_mountpoint
    list_datasets.sort! { |a, b| a.mountpoint <=> b.mountpoint }
  end

  def list_datasets
    ret = []
    current_ds = nil
    skip_current = false

    Open3.popen2(
      'zfs', 'get', '-Hrp', '-t', 'filesystem', '-o', 'name,property,value',
      'canmount,mounted,mountpoint', pool
    ) do |stdin, stdout, status_thread|
      stdout.each_line do |line|
        name, property, value = line.split

        if current_ds.nil?
          current_ds = Dataset.new(name, nil)

        elsif current_ds && current_ds.name != name
          if skip_current
            skip_current = false
          else
            ret << current_ds
          end

          current_ds = Dataset.new(name, nil)
        end

        if skip_current
          next
        elsif (property == 'canmount' && value != 'on') \
              || (property == 'mounted' && value == 'yes') \
              || (property == 'mountpoint' && value == 'legacy')
          skip_current = true
          next
        end

        current_ds.mountpoint = value if property == 'mountpoint'
      end

      fail 'Unable to list filesystems' unless status_thread.value.success?
    end

    ret << current_ds if current_ds && !skip_current
    ret
  end
end

if ARGV.count != 1
  warn "Usage: $0 <pool>"
  exit(false)
elsif Process.uid != 0
  warn "Must be run as root"
  exit(false)
end

Pool.mount_all(ARGV[0])
