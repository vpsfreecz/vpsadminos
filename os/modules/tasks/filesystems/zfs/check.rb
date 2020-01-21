#!@ruby@/bin/ruby
require 'optparse'

dirs = []

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [-d devicedir] <pool> [id]"
  opts.on('-d DEVICEDIR', 'Search for devices in directory') do |v|
    dirs << v
  end
end
parser.parse!

if ARGV.length < 1
  warn parser.banner
  exit(false)
end

pool = ARGV[0]
guid = ARGV[1]
state = 'MISSING'

cmd = [
  '@zfsUser@/bin/zpool',
  'import',
] + dirs.map { |v| "-d \"#{v}\"" }

IO.popen("#{cmd.join(' ')} 2>/dev/null") do |io|
  found_pool = false

  io.each_line do |line|
    k, v = line.strip.split(':')
    next if k.nil?

    attr = k.strip

    if attr == 'pool'
      found_pool = v.strip == pool

    elsif attr == 'id' && guid
      found_pool = false if v.strip != guid

    elsif found_pool && attr == 'state'
      state = v.strip
      break
    end
  end
end

puts state
