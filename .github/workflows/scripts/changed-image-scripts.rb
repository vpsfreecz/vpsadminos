#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'shellwords'

ZERO_SHA = ('0' * 40).freeze
EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')
default_branch = ENV.fetch('DEFAULT_BRANCH')
current_branch = ENV.fetch('CURRENT_BRANCH')

def run!(*cmd)
  warn "Running #{Shellwords.join(cmd)}"
  stdout, stderr, status = Open3.capture3(*cmd)
  warn stderr unless stderr.empty?
  raise "#{cmd.first} failed" unless status.success?

  stdout
end

def commit_exists?(rev)
  system('git', 'cat-file', '-e', "#{rev}^{commit}", out: File::NULL, err: File::NULL)
end

def zero_sha?(rev)
  rev.nil? || rev.empty? || rev == ZERO_SHA
end

if zero_sha?(base)
  if current_branch == default_branch
    base = EMPTY_TREE
  else
    run!('git', 'fetch', 'origin', default_branch)
    base = run!('git', 'merge-base', "origin/#{default_branch}", head).strip
    raise 'git merge-base returned an empty base revision' if base.empty?
  end
elsif !commit_exists?(base)
  # Fetch the base commit in case of a force-push.
  run!('git', 'fetch', 'origin', base)
end

diff_base = base

unless diff_base == EMPTY_TREE || zero_sha?(diff_base) \
       || system('git', 'merge-base', '--is-ancestor', base, head, out: File::NULL, err: File::NULL)
  diff_base = run!('git', 'merge-base', base, head).strip
  raise 'git merge-base returned an empty base revision' if diff_base.empty?

  warn "Base #{base} is not an ancestor of #{head}, using merge-base #{diff_base}"
end

changed_files = run!('git', 'diff', '--name-only', diff_base, head).split("\n")

img_root = 'image-scripts/images'
include_root = 'image-scripts/include'
nixos_dir = 'os/lib/nixos-container'
all_images = Dir.entries(img_root).reject { |v| %w[. ..].include?(v) }
test_images = []

def abstract_image?(img_root, image)
  dir = File.join(img_root, image)

  !File.symlink?(dir) && File.exist?(File.join(dir, 'abstract'))
end

warn 'Changed files:'
changed_files.each do |v|
  warn "- #{v}"
end

# Detect changes in image-scripts/images/
changed_images =
  changed_files.select do |v|
    File.fnmatch?("#{img_root}/**", v)
  end.map do |v|
    # Handle both changes to build scripts and symlinks, e.g.:
    #   image-scripts/images/debian/build.sh (script file)
    #   image-scripts/images/alpine-3.22 (symlink to alpine)
    if v.count('/') >= 3
      File.basename(File.dirname(v))
    else
      File.basename(v)
    end
  end.uniq

# Expand abstract images
changed_images.each do |image|
  dir = File.join(img_root, image)

  if abstract_image?(img_root, image)
    abstract_path = File.realpath(dir)

    all_images.each do |other_image|
      other_dir = File.join(img_root, other_image)
      next unless File.symlink?(other_dir)

      test_images << other_image if File.realpath(other_dir) == abstract_path
    rescue Errno::ENOENT
      next
    end
  elsif all_images.include?(image)
    test_images << image
  end
end

# Special case for NixOS
if changed_files.any? { |v| v.start_with?("#{nixos_dir}/") }
  all_images.each do |image|
    test_images << image if image.start_with?('nixos-')
  end
end

# Detect changes in image-scripts/include
includes_modified = changed_files.select { |v| v.start_with?("#{include_root}/") }

if includes_modified.any?
  Dir.glob("#{img_root}/*/*.sh").each do |script|
    File.open(script) do |f|
      f.each_line do |line|
        found = false

        includes_modified.each do |modified|
          next unless line.include?(File.basename(modified))

          test_images << File.basename(File.dirname(script))
          found = true
          break
        end

        break if found
      end
    end
  end
end

puts test_images.uniq.sort.join(',')
