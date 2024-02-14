#!@ruby@/bin/ruby
# Garbage collect images from osctl image repository
# Expected JSON format is:
#
#   {
#     "gc": [
#       {
#         "vendor": "vpsadminos",
#         "variant": "minimal",
#         "arch": "x86_64",
#         "distribution": "debian",
#         "version": "testing-\d+",
#         "keep": 4
#       },
#       ...
#     ]
#   }
require 'json'

class GarbageCollector
  OSCTL_REPO = '@osctlRepo@/bin/osctl-repo'.freeze

  def initialize(config)
    @matchers = {}
    @images = {}
    read_config(config)
  end

  def run
    read_repo

    images.each do |vendor, variants|
      variants.each do |variant, archs|
        archs.each do |arch, dists|
          dists.each do |dist, versions|
            lists = {}

            versions.each do |ver|
              entry = match(vendor, variant, arch, dist, ver)

              if entry
                lists[entry] ||= []
                lists[entry] << ver
              end
            end

            lists.each do |entry, candidates|
              candidates.each_with_index do |c, i|
                if i < candidates.count - entry['keep']
                  puts "Destroy #{dist}-#{c}"
                  system("#{OSCTL_REPO} local rm #{vendor} #{variant} #{arch} #{dist} #{c}")
                else
                  puts "Keep #{dist}-#{c}"
                end
              end
            end
          end
        end
      end
    end
  end

  protected

  attr_reader :matchers, :images

  def read_config(path)
    @matchers = JSON.parse(File.read(path))['gc'].map do |m|
      m.to_h do |k, v|
        case k
        when 'keep'
          [k, v]
        else
          [k, v.nil? ? nil : Regexp.new(v)]
        end
      end
    end
  end

  def read_repo
    lines = `#{OSCTL_REPO} local ls`.strip.split("\n")[1..]
    lines.each do |line|
      vendor, variant, arch, dist, ver, tags = line.split

      images[vendor] ||= {}
      images[vendor][variant] ||= {}
      images[vendor][variant][arch] ||= {}
      images[vendor][variant][arch][dist] ||= []
      images[vendor][variant][arch][dist] << ver
    end
  end

  def match(vendor, variant, arch, dist, ver)
    matchers.detect do |m|
      (m['vendor'].nil? || m['vendor'] =~ vendor) \
      && (m['variant'].nil? || m['variant'] =~ variant) \
      && (m['arch'].nil? || m['arch'] =~ arch) \
      && (m['distribution'].nil? || m['distribution'] =~ dist) \
      && (m['version'].nil? || m['version'] =~ ver)
    end
  end
end

if ARGV.length != 1
  warn 'Usage: $0 <json config>'
  exit(false)
end

gc = GarbageCollector.new(ARGV[0])
gc.run
