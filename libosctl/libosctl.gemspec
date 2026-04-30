lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'libosctl/version'

Gem::Specification.new do |s|
  s.name = 'libosctl'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::Lib::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::Lib::VERSION
              end

  s.summary     =
    s.description = 'Shared library for osctl from vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z 2>/dev/null`.split("\x0")
  s.files       = Dir.glob(%w[bin/**/* configs/**/* ext/**/* hooks/**/* lib/**/* man/**/* migrations/**/* templates/**/*]).select { |f| File.file?(f) } if s.files.empty?
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.extensions << 'ext/libosctl/extconf.rb'
  s.license     = 'MIT'

  ruby_version_file = File.expand_path('../.ruby-version', __dir__)
  ruby_version = File.exist?(ruby_version_file) ? File.read(ruby_version_file).strip : '3.4.0'
  s.required_ruby_version = ">= #{ruby_version}"

  s.add_dependency 'fiddle'
  s.add_dependency 'logger'
  s.add_dependency 'rainbow', '~> 3.1.1'
  s.add_dependency 'require_all', '~> 2.0.0'
  s.add_dependency 'syslog'
end
