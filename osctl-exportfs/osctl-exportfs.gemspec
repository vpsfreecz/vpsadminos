lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'osctl/exportfs/version'

Gem::Specification.new do |s|
  s.name        = 'osctl-exportfs'

  if ENV['OS_BUILD_ID']
    s.version   = "#{OsCtl::ExportFS::VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = OsCtl::ExportFS::VERSION
  end

  s.summary     =
  s.description = 'Manage dedicated NFS servers for filesystem exports'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'Apache-2.0'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'gli', '~> 2.17.1'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'require_all', '~> 2.0.0'
  s.add_development_dependency 'md2man'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'yard'
end
