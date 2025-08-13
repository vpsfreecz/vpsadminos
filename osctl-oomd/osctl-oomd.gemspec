lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/oomd/version'

Gem::Specification.new do |s|
  s.name = 'osctl-oomd'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtl::Oomd::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtl::Oomd::VERSION
              end

  s.summary     =
    s.description = 'Out-of-memory killer for containers'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'osctl', s.version
  s.add_dependency 'prometheus-client', '~> 4.2.3'
end
