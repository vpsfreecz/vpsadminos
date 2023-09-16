lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'test-runner/version'

Gem::Specification.new do |s|
  s.name        = 'test-runner'

  if ENV['OS_BUILD_ID']
    s.version   = "#{TestRunner::VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = TestRunner::VERSION
  end

  s.summary     =
  s.description = "vpsAdminOS test suite evaluator"
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'pry', '~> 0.13.1'
  s.add_runtime_dependency 'osvm', s.version
  s.add_development_dependency 'md2man'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'yard'
end
