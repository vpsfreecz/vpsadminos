#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'

def usage
  abort "Usage: #{$0} <packages-dir> <gem-name>"
end

def run!(*cmd, chdir: nil, env: {})
  opts = {}
  opts[:chdir] = chdir if chdir

  ok = system(env, *cmd, **opts)
  return if ok

  status = $?&.exitstatus || 1
  abort "#{cmd.shelljoin} failed with exit status #{status}"
end

def capture_json!(*cmd, chdir: nil, env: {})
  opts = {}
  opts[:chdir] = chdir if chdir

  out, err, status = Open3.capture3(env, *cmd, **opts)
  abort "#{cmd.shelljoin} failed with exit status #{status.exitstatus}: #{err}" unless status.success?

  JSON.parse(out)
end

def flake_input_paths(root)
  archive = capture_json!('nix', 'flake', 'archive', '--json', root)
  inputs = archive.fetch('inputs')

  {
    'NETLINKRB_PATH' => inputs.fetch('netlinkrb').fetch('path'),
    'RUBY_LXC_PATH' => inputs.fetch('ruby-lxc').fetch('path')
  }
end

def gem_declarations(gemfile, source_gems)
  gemfile.lines.filter_map do |line|
    match = line.match(/^\s*gem ['"]([^'"]+)['"](?:,\s*['"]([^'"]+)['"])?/)
    next if match.nil?

    name = match[1]
    next unless source_gems.include?(name)

    [name, match[2]]
  end
end

def source_spec_lines(section)
  lines = section.lines
  spec_index = lines.index("  specs:\n")
  return [] if spec_index.nil?

  lines[(spec_index + 1)..] || []
end

def spec_blocks(lines)
  blocks = []
  current = nil

  lines.each do |line|
    if line.match?(/^    \S/)
      blocks << current if current
      current = [line]
    elsif current
      current << line
    end
  end

  blocks << current if current
  blocks
end

def normalize_dependencies(section, source_gems, canonical_deps)
  lines = section.lines
  kept = lines[1..].to_a.reject do |line|
    name = line[/^\s{2}([^ !(]+)/, 1]
    name && source_gems.include?(name)
  end

  source_lines = canonical_deps.map do |name, version|
    if version
      "  #{name} (= #{version})!\n"
    else
      "  #{name}!\n"
    end
  end

  ["DEPENDENCIES\n"] + (source_lines + kept).sort
end

def normalize_lockfile(path, source_gems, canonical_deps, bundled_with)
  sections = File.read(path).split(/\n(?=[A-Z][A-Z0-9 _-]*\n)/)
  source_specs = []
  kept_sections = []

  sections.each do |section|
    case section.lines.first&.strip
    when 'PATH'
      source_specs.concat(source_spec_lines(section))
    when 'GEM'
      lines = section.lines
      spec_index = lines.index("  specs:\n")
      abort 'Gemfile.lock has no GEM specs section' if spec_index.nil?

      prefix = lines[0..spec_index]
      blocks = spec_blocks(lines[(spec_index + 1)..].to_a + source_specs)
      sorted_specs = blocks.sort_by { |block| block.first[/^    ([^ (]+)/, 1] || '' }.flatten

      kept_sections << (prefix + sorted_specs).join
    when 'DEPENDENCIES'
      kept_sections << normalize_dependencies(section, source_gems, canonical_deps).join
    when 'BUNDLED WITH'
      kept_sections << if bundled_with
                         "BUNDLED WITH\n   #{bundled_with}\n"
                       else
                         section.sub(/\n+\z/, "\n")
                       end
    when 'CHECKSUMS'
      next
    else
      kept_sections << section.sub(/\n+\z/, "\n")
    end
  end

  normalized = kept_sections.map { |section| section.sub(/\n+\z/, '') }.join("\n\n")
  File.write(path, "#{normalized}\n")
end

def nix_expr_string(str)
  str.inspect
end

def nix_attr_name(str)
  if str.match?(/\A[A-Za-z_][A-Za-z0-9_'-]*\z/)
    str
  else
    nix_expr_string(str)
  end
end

def nix_value(value, indent = 0)
  pad = '  ' * indent
  child_pad = '  ' * (indent + 1)

  case value
  when Hash
    return '{ }' if value.empty?

    lines = ['{']
    value.keys.sort.each do |key|
      lines << "#{child_pad}#{nix_attr_name(key)} = #{nix_value(value.fetch(key), indent + 1)};"
    end
    lines << "#{pad}}"
    lines.join("\n")
  when Array
    return '[ ]' if value.empty?

    if value.all? { |v| v.is_a?(String) }
      "[ #{value.map { |v| nix_expr_string(v) }.join(' ')} ]"
    else
      lines = ['[']
      value.each { |v| lines << "#{child_pad}#{nix_value(v, indent + 1)}" }
      lines << "#{pad}]"
      lines.join("\n")
    end
  when String
    nix_expr_string(value)
  when TrueClass
    'true'
  when FalseClass
    'false'
  when NilClass
    'null'
  else
    value.to_s
  end
end

def normalize_gemset(path, source_gems)
  data = capture_json!('nix', 'eval', '--json', '--file', path)

  source_gems.each do |name|
    next unless data.has_key?(name)

    data.fetch(name)['source'] = { 'type' => 'gem' }
  end

  File.write(path, "#{nix_value(data)}\n")
  run!('nixfmt', path)
end

usage unless ARGV.length == 2

root = File.expand_path('..', __dir__)
packages_dir = ARGV.fetch(0)
gem_name = File.basename(ARGV.fetch(1))
package_dir = File.join(root, packages_dir, gem_name)

abort "Package directory not found: #{package_dir}" unless Dir.exist?(package_dir)

flake_input_paths(root).each do |key, path|
  ENV[key] = path if ENV[key].to_s.empty?
end

source_paths = {
  'libosctl' => File.join(root, 'libosctl'),
  'netlinkrb' => ENV.fetch('NETLINKRB_PATH'),
  'osctl' => File.join(root, 'osctl'),
  'osctl-env-exec' => File.join(root, 'tools/osctl-env-exec'),
  'osctl-exporter' => File.join(root, 'osctl-exporter'),
  'osctl-exportfs' => File.join(root, 'osctl-exportfs'),
  'osctl-image' => File.join(root, 'osctl-image'),
  'osctl-oomd' => File.join(root, 'osctl-oomd'),
  'osctl-repo' => File.join(root, 'osctl-repo'),
  'osctld' => File.join(root, 'osctld'),
  'osup' => File.join(root, 'osup'),
  'osvm' => File.join(root, 'osvm'),
  'ruby-lxc' => ENV.fetch('RUBY_LXC_PATH'),
  'svctl' => File.join(root, 'svctl'),
  'test-runner' => File.join(root, 'test-runner')
}

source_closures = {
  'osctl' => %w[libosctl osctl],
  'osctld' => %w[libosctl netlinkrb osctld osctl-repo osup ruby-lxc],
  'osctl-env-exec' => %w[osctl-env-exec],
  'osctl-exporter' => %w[libosctl osctl osctl-exporter osctl-exportfs],
  'osctl-exportfs' => %w[libosctl osctl-exportfs],
  'osctl-image' => %w[libosctl osctl osctl-image osctl-repo],
  'osctl-oomd' => %w[libosctl osctl osctl-oomd],
  'osctl-repo' => %w[libosctl osctl-repo],
  'osup' => %w[libosctl osup],
  'osvm' => %w[libosctl osvm],
  'svctl' => %w[libosctl svctl],
  'test-runner' => %w[libosctl osvm test-runner]
}

source_gems = source_paths.keys
selected_sources = source_closures.fetch(gem_name) do
  abort "Unknown packaged source gem: #{gem_name}"
end

Dir.chdir(package_dir) do
  original_gemfile = File.read('Gemfile')
  original_lockfile = File.exist?('Gemfile.lock') ? File.read('Gemfile.lock') : nil
  bundled_with = ENV['BUNDLED_WITH'] || original_lockfile&.match(/^BUNDLED WITH\n\s+(.+)\n/m)&.[](1)
  canonical_deps = gem_declarations(original_gemfile, source_gems)
  seen_sources = {}

  rewritten = original_gemfile.each_line.with_object(+'') do |line, ret|
    match = line.match(/^\s*gem ['"]([^'"]+)['"]/)

    if match && selected_sources.include?(match[1])
      name = match[1]
      seen_sources[name] = true
      ret << "gem #{name.inspect}, path: #{source_paths.fetch(name).inspect}\n"
    else
      ret << line
    end
  end

  (selected_sources - seen_sources.keys).each do |name|
    rewritten << "\n" unless rewritten.end_with?("\n")
    rewritten << "gem #{name.inspect}, path: #{source_paths.fetch(name).inspect}\n"
  end

  FileUtils.rm_f(%w[Gemfile.lock gemset.nix])
  File.write('Gemfile', rewritten)

  begin
    run!('bundle', 'lock', '--add-platform', 'ruby', '--add-platform', 'x86_64-linux')
    run!('bundix', '-l')
  ensure
    File.write('Gemfile', original_gemfile)
  end

  normalize_lockfile('Gemfile.lock', source_gems, canonical_deps, bundled_with)
  normalize_gemset('gemset.nix', source_gems)
end
