# frozen_string_literal: true

require 'overcommit'
require 'tempfile'

ruby = ARGV.fetch(0)
unless ruby.match?(%r{\A/nix/store/[a-z0-9]{32}-[^/\s]+/bin/ruby\z}) && File.executable?(ruby)
  abort 'Expected an executable Nix store Ruby for the retention hooks'
end

# Operate only in the standalone Actions checkout, never in linked or shared
# Git hook directories. Overcommit installs one regular copy per hook type.
hooks = File.join(Dir.pwd, '.git', 'hooks')
unless File.realpath(hooks) == hooks && File.expand_path(Overcommit::GitConfig.hooks_path) == hooks
  abort 'Expected checkout-local Git hooks for kernel retention'
end
master_name = 'overcommit-hook'
entrypoints = Overcommit::Utils.supported_hook_types.map(&:to_s)
names = [master_name, *entrypoints]
required = %w[post-checkout pre-commit commit-msg]
unless (required - names).empty? && (Dir.children(hooks).reject { |name| name.end_with?('.sample') } - names).empty?
  abort 'Unexpected Git hook layout for kernel retention'
end

master = File.binread(Overcommit::Installer::MASTER_HOOK)
shebang, newline, body = master.partition("\n")
unless !newline.empty? && (shebang == '#!/usr/bin/env ruby' || shebang.match?(%r{\A#!/nix/store/[^/\s]+/bin/ruby\z}))
  abort 'Unexpected packaged Overcommit hook interpreter'
end
modes = names.to_h do |name|
  path = File.join(hooks, name)
  info = File.lstat(path)
  unless info.file? && info.uid == Process.euid && info.nlink == 1 && File.executable?(path) && File.binread(path) == master
    abort "Installed #{name} does not match the packaged Overcommit hook"
  end
  [name, info.mode & 0o7777]
end
puts "Installed Overcommit post-checkout interpreter: #{shebang}"

bound = "#!#{ruby}\n#{body}"
# Overcommit compares the installed master to the packaged template to detect
# upgrades. Keep that sentinel unchanged and bind only the hook entry points.
entrypoints.each do |name|
  # Packaged hook copies can be read-only. Do not truncate or chmod them.
  Tempfile.create('.retention-hook-', hooks, binmode: true) do |replacement|
    replacement.write(bound)
    replacement.flush
    replacement.chmod(modes.fetch(name))
    File.rename(replacement.path, File.join(hooks, name))
  end
end
modes.each do |name, mode|
  path = File.join(hooks, name)
  expected = name == master_name ? master : bound
  unless File.binread(path) == expected && (File.stat(path).mode & 0o7777) == mode
    abort "Could not verify the installed Overcommit #{name}"
  end
end
required.each { |name| puts "Bound #{name} to #{ruby}" }
