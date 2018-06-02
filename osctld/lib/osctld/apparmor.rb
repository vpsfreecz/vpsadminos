require 'libosctl'

module OsCtld
  module AppArmor
    include OsCtl::Lib::Utils::Log
    extend OsCtl::Lib::Utils::System

    def self.setup
      unless ENV['OSCTLD_APPARMOR_PATHS']
        fail 'missing env var OSCTLD_APPARMOR_PATHS'
      end

      base = File.join(OsCtld.root, 'configs', 'apparmor.d')

      paths = ENV['OSCTLD_APPARMOR_PATHS'].split(':')
      paths << base

      syscmd(
        "apparmor_parser -rKv #{paths.map { |v| "-I #{v}" }.join(' ')} "+
        File.join(base, 'osctl-containers')
      )
    end
  end
end
