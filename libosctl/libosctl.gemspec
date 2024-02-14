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
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_runtime_dependency 'rainbow', '~> 3.1.1'
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
end
