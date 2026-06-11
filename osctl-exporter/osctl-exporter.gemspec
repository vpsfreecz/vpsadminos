lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctl/exporter/version'

Gem::Specification.new do |s|
  s.name = 'osctl-exporter'

  s.version = OsCtl::Exporter::VERSION

  s.summary     =
    s.description = 'Export osctl metrics to prometheus'
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

  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'osctl', s.version
  s.add_dependency 'osctl-exportfs', s.version
  s.add_dependency 'prometheus-client', '~> 4.2.3'
  s.add_dependency 'puma'
  s.add_dependency 'rack', '~> 3.1'
  s.add_dependency 'require_all', '~> 2.0.0'
end
