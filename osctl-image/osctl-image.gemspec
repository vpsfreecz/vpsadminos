lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/image/version'

Gem::Specification.new do |s|
  s.name = 'osctl-image'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::Image::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::Image::VERSION
              end

  s.summary     =
    s.description = 'Build, test and deploy vpsAdminOS images'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'ipaddress', '~> 0.8.3'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'osctl', s.version
  s.add_runtime_dependency 'osctl-repo', s.version
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
  s.add_development_dependency 'md2man'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'yard'
end
