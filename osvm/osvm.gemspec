lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osvm/version'

Gem::Specification.new do |s|
  s.name = 'osvm'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsVm::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsVm::VERSION
              end

  s.summary     =
    s.description = 'Run and interact with vpsAdminOS virtual machines'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'libosctl', s.version
end
