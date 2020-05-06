VERSION = '20.03.0'

Gem::Specification.new do |s|
  s.name        = 'osctl-env-exec'

  if ENV['OS_BUILD_ID']
    s.version   = "#{VERSION}.build#{ENV['OS_BUILD_ID']}"
  else
    s.version   = VERSION
  end

  s.summary     =
  s.description = "Gem for bootstraping Ruby environment will all osctl's dependencies"
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z`.split("\x0")
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'Apache-2.0'

  s.required_ruby_version = '>= 2.0.0'

  # List all osctl dependencies as runtime
  s.add_runtime_dependency 'highline', '~> 1.7.10'
  s.add_runtime_dependency 'ipaddress', '~> 0.8.3'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'gli', '~> 2.17.1'
  s.add_runtime_dependency 'ruby-progressbar', '~> 1.9.0'
  s.add_runtime_dependency 'md2man'
  s.add_runtime_dependency 'rake'
  s.add_runtime_dependency 'rake-compiler'
  s.add_runtime_dependency 'yard'
end
