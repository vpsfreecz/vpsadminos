lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'osvm/version'

Gem::Specification.new do |s|
  s.name        = 'osvm'

  if ENV['OS_BUILD_ID']
    s.version   = "#{OsVm::VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = OsVm::VERSION
  end

  s.summary     =
  s.description = "Run and interact with vpsAdminOS virtual machines"
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_development_dependency 'md2man'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'yard'
end
