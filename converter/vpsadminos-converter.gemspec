lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'vpsadminos-converter/version'

Gem::Specification.new do |s|
  s.name = 'vpsadminos-converter'

  s.version = if ENV['OS_BUILD_ID']
                "#{VpsAdminOS::Converter::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                VpsAdminOS::Converter::VERSION
              end

  s.summary     =
    s.description = 'Convert OpenVZ containers into vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'highline', '~> 2.0.3'
  s.add_runtime_dependency 'ipaddress', '~> 0.8.3'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
  s.add_runtime_dependency 'ruby-progressbar', '~> 1.11.0'
end
