lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'osctld/version'

Gem::Specification.new do |s|
  s.name        = 'osctld'

  if ENV['VPSADMIN_ENV'] == 'dev'
    s.version   = "#{OsCtld::VERSION}.build#{Time.now.strftime('%Y%m%d%H%M%S')}"
  else
    s.version   = OsCtld::VERSION
  end

  s.summary     =
  s.description = 'Management daemon for vpsAdmin OS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'GPL'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'ruby-lxc', '~> 1.2.2'
end
