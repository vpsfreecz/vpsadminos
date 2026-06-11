lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osup/version'

Gem::Specification.new do |s|
  s.name = 'osup'

  s.version = OsUp::VERSION

  s.summary     =
    s.description = 'System upgrade manager for vpsAdminOS'
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
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_dependency 'gli', '~> 2.22.0'
  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'require_all', '~> 2.0.0'
end
