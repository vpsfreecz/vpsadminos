#!@ruby@/bin/ruby
require 'open3'

class Pool
  def self.share_all(pool)
    p = new(pool)
    p.share_all
  end

  attr_reader :pool

  def initialize(pool)
    @pool = pool
  end

  def share_all
    datasets = list_datasets
    cnt = datasets.count

    datasets.each_with_index do |ds, i|
      puts "[#{i+1}/#{cnt}] Sharing #{ds}"
      Kernel.system('zfs', 'share', ds)
    end
  end

  protected
  def list_datasets
    ret = []

    Open3.popen2(
      'zfs', 'list', '-Hr', '-t', 'filesystem', '-o', 'name,mounted,sharenfs',
      pool
    ) do |stdin, stdout, status_thread|
      stdout.each_line do |line|
        name, mounted, sharenfs = line.split
        ret << name if mounted == 'yes' && sharenfs != 'off'
      end

      fail 'Unable to list filesystems' unless status_thread.value.success?
    end

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

Pool.share_all(ARGV[0])
