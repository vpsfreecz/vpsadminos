#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'optparse'
require 'pathname'

ROCKY_ROOT = 'https://ftp.linux.cz/pub/linux/rocky'
ALMALINUX_ROOT = 'https://repo.almalinux.org/almalinux'
CENTOS_STREAM_ROOT = 'https://mirror.stream.centos.org'
FEDORA_RELEASES_ROOT = 'http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases'
FEDORA_RAWHIDE_PACKAGES = 'http://ftp.fi.muni.cz/pub/linux/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/f/'
FEDORA_RELEASE_NAMES = %w[
  fedora-release-server
  fedora-release
  fedora-release-common
  fedora-release-identity-basic
].freeze

def version_key(value)
  value.scan(/\d+|\D+/).map do |part|
    part.match?(/\A\d+\z/) ? part.to_i : part
  end
end

def fetch(url)
  uri = URI.parse(url)
  response = Net::HTTP.get_response(uri)

  return response.body if response.is_a?(Net::HTTPSuccess)

  raise "failed to fetch #{url}: #{response.code} #{response.message}"
rescue SocketError, SystemCallError, IOError => e
  raise "failed to fetch #{url}: #{e.message}"
end

def parse_assignment(lines, name)
  line = lines.grep(/\A#{Regexp.escape(name)}=/).first
  raise "unable to find #{name}" if line.nil?

  line.split('=', 2).last
end

def expand_variables(value, replacements)
  replacements.each do |key, replacement|
    value = value.gsub("${#{key}}", replacement)
    value = value.gsub("$#{key}", replacement)
  end

  value
end

def extract_dir_versions(html)
  html.scan(%r{href="([0-9]+\.[0-9]+)/"}).flatten.uniq.sort_by { |version| version_key(version) }
end

def latest_point_version(root, major)
  versions = extract_dir_versions(fetch("#{root}/")).select do |version|
    version.start_with?("#{major}.")
  end

  raise "no point version found for #{root} major #{major}" if versions.empty?

  versions.last
end

def find_filenames(url, pattern)
  fetch(url).scan(pattern).flatten.uniq.sort_by { |value| version_key(value) }
end

def current_release_filename(raw_value, replacements)
  expanded = expand_variables(raw_value, replacements)
  expanded.split('/').last.delete('"')
end

def stable_fedora_release_suffix(build_lines)
  match = build_lines.join("\n").match(
    /fedora-release-server-\$RELVER-([0-9]+)\.noarch\.rpm/
  )
  raise 'unable to find fedora stable release suffix' if match.nil?

  match[1]
end

def common_fedora_versions(url, value_pattern)
  html = fetch(url)
  versions = nil

  FEDORA_RELEASE_NAMES.each do |package_name|
    matches = html.scan(/#{package_name}-#{value_pattern}\.noarch\.rpm/).flatten.uniq
    versions = versions.nil? ? matches : versions & matches
  end

  raise "no shared Fedora release values found in #{url}" if versions.nil? || versions.empty?

  versions.to_a.sort_by { |value| version_key(value) }
end

def rocky_result(image_name, build_path)
  major = image_name.split('-', 2).last
  build_lines = build_path.read.split("\n")
  current_pointver = parse_assignment(build_lines, 'POINTVER')
  current_release = current_release_filename(
    parse_assignment(build_lines, 'RELEASE'),
    { 'POINTVER' => current_pointver }
  )
  latest_pointver = latest_point_version(ROCKY_ROOT, major)
  packages_url = "#{ROCKY_ROOT}/#{latest_pointver}/BaseOS/x86_64/os/Packages/r/"
  latest_release = find_filenames(
    packages_url,
    /(rocky-release-#{Regexp.escape(latest_pointver)}-[^"'<> ]+\.rpm)/
  ).last

  {
    image: image_name,
    file: build_path,
    status: current_pointver != latest_pointver || current_release != latest_release,
    current_pointver: current_pointver,
    latest_pointver: latest_pointver,
    current_release: current_release,
    latest_release: latest_release,
    packages_url: packages_url
  }
end

def almalinux_result(image_name, build_path)
  major = image_name.split('-', 2).last
  build_lines = build_path.read.split("\n")
  current_pointver = parse_assignment(build_lines, 'POINTVER')
  current_release = current_release_filename(
    parse_assignment(build_lines, 'RELEASE'),
    {
      'POINTVER' => current_pointver,
      'RELVER' => major
    }
  )
  latest_pointver = latest_point_version(ALMALINUX_ROOT, major)
  packages_url = "#{ALMALINUX_ROOT}/#{latest_pointver}/BaseOS/x86_64/os/Packages/"
  latest_release = find_filenames(
    packages_url,
    /(almalinux-release-#{Regexp.escape(latest_pointver)}-[^"'<> ]+\.rpm)/
  ).last

  {
    image: image_name,
    file: build_path,
    status: current_pointver != latest_pointver || current_release != latest_release,
    current_pointver: current_pointver,
    latest_pointver: latest_pointver,
    current_release: current_release,
    latest_release: latest_release,
    packages_url: packages_url
  }
end

def centos_stream_result(image_name, build_path)
  match = image_name.match(/\Acentos-(\d+)-stream\z/)
  raise "unable to parse CentOS Stream image name #{image_name}" if match.nil?

  major = match[1]
  build_lines = build_path.read.split("\n")
  current_pointver = parse_assignment(build_lines, 'POINTVER')
  current_release = current_release_filename(
    parse_assignment(build_lines, 'RELEASE'),
    { 'POINTVER' => current_pointver }
  )
  packages_url = "#{CENTOS_STREAM_ROOT}/#{major}-stream/BaseOS/x86_64/os/Packages/"
  latest_release = find_filenames(
    packages_url,
    /(centos-stream-release-[0-9]+\.[0-9]+-[^"'<> ]+\.rpm)/
  ).last
  latest_pointver = latest_release.match(
    /\Acentos-stream-release-([0-9]+\.[0-9]+)-/
  )&.[](1)
  raise "unable to parse CentOS Stream point version from #{latest_release}" if latest_pointver.nil?

  {
    image: image_name,
    file: build_path,
    status: current_pointver != latest_pointver || current_release != latest_release,
    current_pointver: current_pointver,
    latest_pointver: latest_pointver,
    current_release: current_release,
    latest_release: latest_release,
    packages_url: packages_url
  }
end

def centos_stream_image?(image_name)
  image_name.match?(/\Acentos-\d+-stream\z/)
end

def fedora_stable_result(image_name, build_path)
  relver = image_name.split('-', 2).last
  build_lines = build_path.read.split("\n")
  current_suffix = stable_fedora_release_suffix(build_lines)
  packages_url = "#{FEDORA_RELEASES_ROOT}/#{relver}/Everything/x86_64/os/Packages/f/"
  latest_suffix = common_fedora_versions(packages_url, "#{relver}-([0-9]+)").last

  {
    image: image_name,
    file: build_path,
    status: current_suffix != latest_suffix,
    current_suffix: current_suffix,
    latest_suffix: latest_suffix,
    packages_url: packages_url
  }
rescue RuntimeError => e
  {
    image: image_name,
    file: build_path,
    stale: true,
    reason: "not present on the live Fedora releases mirror (#{e.message})",
    packages_url: packages_url
  }
end

def fedora_rawhide_result(image_name, build_path)
  build_lines = build_path.read.split("\n")
  current_relver = parse_assignment(build_lines, 'RAWHIDE_RELVER')
  latest_relver = common_fedora_versions(
    FEDORA_RAWHIDE_PACKAGES,
    '([0-9]+-[0-9.]+)'
  ).last

  {
    image: image_name,
    file: build_path,
    status: current_relver != latest_relver,
    current_relver: current_relver,
    latest_relver: latest_relver,
    packages_url: FEDORA_RAWHIDE_PACKAGES
  }
end

def select_images(images_dir, scope)
  images_dir.children.select(&:directory?).select do |path|
    case scope
    when 'rocky'
      path.basename.to_s.start_with?('rocky-')
    when 'almalinux'
      path.basename.to_s.start_with?('almalinux-')
    when 'fedora'
      path.basename.to_s.start_with?('fedora-')
    when 'centos-stream', 'centos'
      centos_stream_image?(path.basename.to_s)
    when 'all'
      path.basename.to_s.start_with?('rocky-', 'almalinux-', 'fedora-') ||
        centos_stream_image?(path.basename.to_s)
    else
      false
    end
  end.sort_by { |path| version_key(path.basename.to_s) }
end

def print_result(result)
  state =
    if result[:stale]
      'stale'
    elsif result[:status]
      'needs update'
    else
      'up to date'
    end
  puts "#{result[:image]} [#{state}]"
  puts "  file: #{result[:file]}"

  if result.has_key?(:current_pointver)
    puts "  current POINTVER: #{result[:current_pointver]}"
    puts "  latest POINTVER: #{result[:latest_pointver]}"
    puts "  current RELEASE: #{result[:current_release]}"
    puts "  latest RELEASE: #{result[:latest_release]}"
    puts "  packages listing: #{result[:packages_url]}"
  elsif result[:stale]
    puts '  status: stale build script'
    puts "  packages listing: #{result[:packages_url]}"
    puts '  action: remove this Fedora image instead of updating it'
    puts "  reason: #{result[:reason]}"
  elsif result.has_key?(:latest_suffix)
    puts "  current release suffix: #{result[:current_suffix]}"
    puts "  latest release suffix: #{result[:latest_suffix]}"
    puts "  packages listing: #{result[:packages_url]}"
  else
    puts "  current RAWHIDE_RELVER: #{result[:current_relver]}"
    puts "  latest RAWHIDE_RELVER: #{result[:latest_relver]}"
    puts "  packages listing: #{result[:packages_url]}"
  end

  unless result[:stale]
    puts "  test: ./test-runner.sh test image-scripts/test@#{result[:image]}"
  end
  puts
end

def parse_options(argv)
  options = {
    repo: '.'
  }

  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: discover_release_updates.rb <scope> [--repo PATH]'

    opts.on('--repo PATH', 'path to the repository root') do |path|
      options[:repo] = path
    end
  end

  parser.parse!(argv)
  scope = argv.shift

  unless %w[rocky almalinux centos-stream centos fedora all].include?(scope)
    warn parser.banner
    warn 'scope must be one of: rocky, almalinux, centos-stream, centos, fedora, all'
    exit 1
  end

  [scope, Pathname.new(options[:repo]).realpath]
end

def main(argv)
  scope, repo = parse_options(argv)
  images_dir = repo.join('image-scripts/images')

  unless images_dir.directory?
    warn "error: #{images_dir} does not exist"
    return 1
  end

  images = select_images(images_dir, scope)
  if images.empty?
    warn "error: no images found for scope #{scope}"
    return 1
  end

  images.each do |image_dir|
    build_path = image_dir.join('build.sh')
    result =
      if image_dir.basename.to_s.start_with?('rocky-')
        rocky_result(image_dir.basename.to_s, build_path)
      elsif image_dir.basename.to_s.start_with?('almalinux-')
        almalinux_result(image_dir.basename.to_s, build_path)
      elsif centos_stream_image?(image_dir.basename.to_s)
        centos_stream_result(image_dir.basename.to_s, build_path)
      elsif image_dir.basename.to_s == 'fedora-rawhide'
        fedora_rawhide_result(image_dir.basename.to_s, build_path)
      else
        fedora_stable_result(image_dir.basename.to_s, build_path)
      end

    print_result(result)
  end

  0
rescue RuntimeError => e
  warn "error: #{e.message}"
  1
end

exit(main(ARGV))
