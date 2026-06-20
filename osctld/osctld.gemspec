lib = File.expand_path('lib', __dir__)
$:.unshift(lib) unless $:.include?(lib)
require 'osctld/version'

Gem::Specification.new do |s|
  s.name = 'osctld'

  s.version = if ENV['OS_BUILD_ID']
                "#{OsCtld::VERSION}.build#{ENV['OS_BUILD_ID']}"
              else
                OsCtld::VERSION
              end

  s.summary       =
    s.description = 'Management daemon for vpsAdminOS'
  s.authors       = 'Jakub Skokan'
  s.email         = 'jakub.skokan@vpsfree.cz'
  s.files         = `git ls-files -z 2>/dev/null`.split("\x0")
  s.files         = Dir.glob(%w[bin/**/* configs/**/* ext/**/* hooks/**/* lib/**/* man/**/* migrations/**/* templates/**/*]).select { |f| File.file?(f) } if s.files.empty?
  s.executables   = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.extensions   << 'ext/osctld/extconf.rb'
  s.require_paths = %w[lib ext]
  s.license       = 'MIT'

  ruby_version_file = File.expand_path('../.ruby-version', __dir__)
  ruby_version = File.exist?(ruby_version_file) ? File.read(ruby_version_file).strip : '3.4.0'
  s.required_ruby_version = ">= #{ruby_version}"

  s.add_dependency 'base64'
  s.add_dependency 'bindata', '~> 2.5.0'
  s.add_dependency 'concurrent-ruby', '~> 1.3.4'
  s.add_dependency 'fiddle'
  s.add_dependency 'ipaddress', '~> 0.8.3'
  s.add_dependency 'json'
  s.add_dependency 'libosctl', s.version
  s.add_dependency 'netlinkrb', '0.18.vpsadminos.0'
  s.add_dependency 'osctl-repo', s.version
  s.add_dependency 'osup', s.version
  s.add_dependency 'require_all', '~> 2.0.0'
  s.add_dependency 'ruby-lxc', '1.2.4.vpsadminos.5'
end
