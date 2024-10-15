lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/version'

Gem::Specification.new do |s|
  s.name = 'osctl'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::VERSION
              end

  s.summary     =
    s.description = 'Management utility for vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_dependency 'curses'
  s.add_dependency 'gli', '~> 2.20.0'
  s.add_dependency 'highline', '~> 2.0.3'
  s.add_dependency 'ipaddress', '~> 0.8.3'
  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'rainbow', '~> 3.1.1'
  s.add_dependency 'require_all', '~> 2.0.0'
  s.add_dependency 'ruby-progressbar', '~> 1.11.0'
  s.add_dependency 'tty-spinner', '~> 0.9.3'
end
