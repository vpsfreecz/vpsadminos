lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'vpsadminos-converter/version'

Gem::Specification.new do |s|
  s.name        = 'vpsadminos-converter'
  
  if ENV['OS_BUILD_ID']
    s.version   = "#{VpsAdminOS::Converter::VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = VpsAdminOS::Converter::VERSION
  end

  s.summary     =
  s.description = 'Convert OpenVZ containers into vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'Apache-2.0'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'highline', '~> 1.7.10'
  s.add_runtime_dependency 'ipaddress', '~> 0.8.3'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'gli', '~> 2.17.1'
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
  s.add_runtime_dependency 'ruby-progressbar', '~> 1.9.0'
  s.add_development_dependency 'md2man'
  s.add_development_dependency 'yard'
end
