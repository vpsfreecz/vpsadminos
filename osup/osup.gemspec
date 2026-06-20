lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osup/version'

Gem::Specification.new do |s|
  s.name = 'osup'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsUp::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsUp::VERSION
              end

  s.summary     =
    s.description = 'System upgrade manager for vpsAdminOS'
  s.authors     = 'Jakub Skokan'
  s.email       = 'jakub.skokan@vpsfree.cz'
  s.files       = `git ls-files -z 2>/dev/null`.split("\x0")
  s.files       = Dir.glob(%w[bin/**/* configs/**/* ext/**/* hooks/**/* lib/**/* man/**/* migrations/**/* templates/**/*]).select { |f| File.file?(f) } if s.files.empty?
  s.files      += Dir['man/man?/*.?']
  s.executables = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.license     = 'MIT'

  ruby_version_file = File.expand_path('../.ruby-version', __dir__)
  ruby_version = File.exist?(ruby_version_file) ? File.read(ruby_version_file).strip : '3.4.0'
  s.required_ruby_version = ">= #{ruby_version}"

  s.add_dependency 'gli', '~> 2.22.0'
  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'require_all', '~> 2.0.0'
end
