#!/usr/bin/env ruby

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')

# Fetch the base commit in case of a force-push
`git fetch origin #{base}`

git_diff = "git diff --name-only #{base} #{head}"
warn "Running #{git_diff}"

changed_files = `#{git_diff}`.split("\n")
raise 'git diff failed' if $?.exitstatus != 0

img_root = 'image-scripts/images'
include_root = 'image-scripts/include'
nixos_dir = 'os/lib/nixos-container'
all_images = Dir.entries(img_root).reject { |v| %w[. ..].include?(v) }
test_images = []

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

  if Dir.exist?(dir) && File.exist?(File.join(dir, 'abstract'))
    all_images.each do |other_image|
      test_images << other_image if File.readlink(File.join(img_root, other_image)).strip == image
    rescue Errno::EINVAL
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
