# frozen_string_literal: true

require 'overcommit'

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
names = ['overcommit-hook', *Overcommit::Utils.supported_hook_types.map(&:to_s)]
required = %w[post-checkout pre-commit commit-msg]
unless (required - names).empty? && (Dir.children(hooks).reject { |name| name.end_with?('.sample') } - names).empty?
  abort 'Unexpected Git hook layout for kernel retention'
end

master = File.binread(Overcommit::Installer::MASTER_HOOK)
shebang, newline, body = master.partition("\n")
unless !newline.empty? && (shebang == '#!/usr/bin/env ruby' || shebang.match?(%r{\A#!/nix/store/[^/\s]+/bin/ruby\z}))
  abort 'Unexpected packaged Overcommit hook interpreter'
end
paths = names.map do |name|
  path = File.join(hooks, name)
  info = File.lstat(path)
  unless info.file? && info.nlink == 1 && File.executable?(path) && File.binread(path) == master
    abort "Installed #{name} does not match the packaged Overcommit hook"
  end
  path
end
puts "Installed Overcommit post-checkout interpreter: #{shebang}"

bound = "#!#{ruby}\n#{body}"
paths.each { |path| File.binwrite(path, bound) }
required.each do |name|
  abort "Could not bind the Overcommit #{name} interpreter" unless File.binread(File.join(hooks, name)) == bound

  puts "Bound #{name} to #{ruby}"
end
