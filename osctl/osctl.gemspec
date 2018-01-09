lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'osctl/version'

Gem::Specification.new do |s|
  s.name        = 'osctl'

  if ENV['VPSADMIN_ENV'] == 'dev'
    s.version   = "#{OsCtl::VERSION}.build#{Time.now.strftime('%Y%m%d%H%M%S')}"
  else
    s.version   = OsCtl::VERSION
  end

  s.summary     =
  s.description = 'Management utility for vpsAdmin OS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'GPL'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'highline', '~> 1.7.10'
  s.add_runtime_dependency 'ipaddress', '~> 0.8.3'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'gli', '~> 2.17.1'
  s.add_development_dependency 'md2man'
end
