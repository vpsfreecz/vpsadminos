lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'test-runner/version'

Gem::Specification.new do |s|
  s.name = 'test-runner'

  s.version = TestRunner::VERSION

  s.summary     =
    s.description = 'vpsAdminOS test suite evaluator'
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
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'osvm', s.version
  s.add_dependency 'pry', '~> 0.16.0'
  s.add_dependency 'rspec-expectations', '~> 3.13'
end
