lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/exporter/version'

Gem::Specification.new do |s|
  s.name = 'osctl-exporter'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::Exporter::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::Exporter::VERSION
              end

  s.summary     =
    s.description = 'Export osctl metrics to prometheus'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'osctl', s.version
  s.add_runtime_dependency 'osctl-exportfs', s.version
  s.add_runtime_dependency 'prometheus-client', '~> 4.0.0'
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
  s.add_runtime_dependency 'thin', '~> 1.8.1'
end
