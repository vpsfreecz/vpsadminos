#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

def usage
  warn 'usage: flake-update-commit-message.rb <inputs|body> <old-lock> <new-lock>'
  2
end

def load_json(path)
  JSON.parse(File.read(path))
end

def locked_map(data)
  nodes = data.fetch('nodes', {})
  nodes.each_with_object({}) do |(name, node), map|
    map[name] = node['locked'] if node.has_key?('locked')
  end
end

def root_inputs(data)
  inputs = data.dig('nodes', 'root', 'inputs') || {}
  inputs.each_with_object({}) do |(input_name, node_name), map|
    node_name = node_name[0] if node_name.is_a?(Array)
    map[input_name] = node_name
  end
end

def changed_inputs(old_data, new_data)
  old_locked = locked_map(old_data)
  new_locked = locked_map(new_data)
  old_root = root_inputs(old_data)
  new_root = root_inputs(new_data)

  changed = []
  new_root.each do |input_name, new_node|
    old_node = old_root[input_name]
    if old_node.nil? || new_node.nil?
      changed << input_name
      next
    end
    changed << input_name if old_locked[old_node] != new_locked[new_node]
  end
  changed.uniq.sort
end

def input_revision(locked)
  return nil unless locked

  %w[rev version narHash ref].each do |key|
    value = locked[key]
    return value if value && !value.empty?
  end
  nil
end

def short_rev(value)
  return 'unknown' if value.nil? || value.empty?

  if value.length >= 9 && value.match?(/\A[0-9a-fA-F]+\z/)
    return value[0, 9]
  end

  return value[0, 9] if value.length > 9

  value
end

def revision_lines(old_data, new_data, inputs)
  old_locked = locked_map(old_data)
  new_locked = locked_map(new_data)
  old_root = root_inputs(old_data)
  new_root = root_inputs(new_data)

  inputs.map do |input_name|
    old_node = old_root[input_name]
    new_node = new_root[input_name]
    old_rev = short_rev(input_revision(old_locked[old_node]))
    new_rev = short_rev(input_revision(new_locked[new_node]))
    "#{input_name}: #{old_rev} -> #{new_rev}"
  end
end

def main(argv)
  return usage if argv.length != 3

  mode, old_path, new_path = argv
  return usage unless %w[inputs body].include?(mode)

  return 0 if !File.exist?(old_path) || !File.exist?(new_path)

  old_data = load_json(old_path)
  new_data = load_json(new_path)
  inputs = changed_inputs(old_data, new_data)

  if mode == 'inputs'
    puts inputs.join(', ')
    return 0
  end

  puts revision_lines(old_data, new_data, inputs).join("\n")
  0
end

exit main(ARGV)
