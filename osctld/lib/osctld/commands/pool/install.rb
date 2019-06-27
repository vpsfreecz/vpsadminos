require 'osctld/commands/base'
require 'osup'

module OsCtld
  class Commands::Pool::Install < Commands::Base
    handle :pool_install

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      if opts[:dataset] && !opts[:dataset].start_with?("#{opts[:name]}/")
        error!("dataset '#{opts[:dataset]}' is not from zpool '#{opts[:name]}'")
      end

      error!('pool already exists') if DB::Pools.contains?(opts[:name])

      props = ["#{Pool::PROPERTY_ACTIVE}=yes"]
      props << "#{Pool::PROPERTY_DATASET}=\"#{opts[:dataset]}\"" if opts[:dataset]

      zfs(:set, props.join(' '), opts[:name])
      OsUp.init(opts[:name], force: true)
      call_cmd!(Commands::Pool::Import, name: opts[:name])
    end
  end
end
