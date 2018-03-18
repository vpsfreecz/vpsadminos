lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'libosctl/version'

Gem::Specification.new do |s|
  s.name        = 'libosctl'

  if ENV['OS_BUILD_ID']
    s.version   = "#{OsCtl::Lib::VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = OsCtl::Lib::VERSION
  end

  s.summary     =
  s.description = 'Shared library for osctl from vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'GPL'

  s.required_ruby_version = '>= 2.0.0'

  s.add_development_dependency 'yard'
end
