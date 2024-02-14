lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'test-runner/version'

Gem::Specification.new do |s|
  s.name = 'test-runner'

  s.version = if ENV['OS_BUILD_ID']
                "#{TestRunner::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                TestRunner::VERSION
              end

  s.summary     =
    s.description = 'vpsAdminOS test suite evaluator'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../.ruby-version').strip}"

  s.add_runtime_dependency 'gli', '~> 2.20.0'
  s.add_runtime_dependency 'libosctl', s.version
  s.add_runtime_dependency 'osvm', s.version
  s.add_runtime_dependency 'pry', '~> 0.13.1'
end
