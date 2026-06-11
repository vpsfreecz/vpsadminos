lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'libosctl/version'

Gem::Specification.new do |s|
  s.name = 'libosctl'

  s.version = OsCtl::Lib::VERSION

  s.summary     =
    s.description = 'Shared library for osctl from vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = Dir[
    'bin/*',
    'configs/**/*',
    'ext/**/*',
    'hooks/**/*',
    'lib/**/*',
    'man/man?/*.?',
    'migrations/**/*',
    'nix/**/*.nix',
    'templates/**/*'
  ].select { |f| File.file?(f) }
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.extensions << 'ext/libosctl/extconf.rb'
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_dependency 'fiddle'
  s.add_dependency 'logger'
  s.add_dependency 'rainbow', '~> 3.1.1'
  s.add_dependency 'require_all', '~> 2.0.0'
  s.add_dependency 'syslog'
end
