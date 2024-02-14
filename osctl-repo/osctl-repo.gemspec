lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/repo/version'

Gem::Specification.new do |s|
  s.name = 'osctl-repo'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::Repo::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::Repo::VERSION
              end

  s.summary     =
    s.description = 'Create and use vpsAdminOS image repositories'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'filelock'
  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
end
