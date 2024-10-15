VERSION = '24.05.0'.freeze

Gem::Specification.new do |s|
  s.name = 'osctl-env-exec'

  s.version = if ENV['OS_BUILD_ID']
                "#{VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                VERSION
              end

  s.summary     =
    s.description = "Gem for bootstraping Ruby environment will all osctl's dependencies"
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  s.required_ruby_version = ">= #{File.read('../../.ruby-version').strip}"

  # List all osctl dependencies as runtime
  s.add_dependency 'gli', '~> 2.20.0'
  s.add_dependency 'highline', '~> 2.0.3'
  s.add_dependency 'ipaddress', '~> 0.8.3'
  s.add_dependency 'json'
  s.add_dependency 'md2man'
  s.add_dependency 'rake'
  s.add_dependency 'rake-compiler'
  s.add_dependency 'ruby-progressbar', '~> 1.11.0'
  s.add_dependency 'yard'
end
