require 'osctld/commands/base'
require 'osup'

module OsCtld
  class Commands::Pool::Install < Commands::Base
    handle :pool_install

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      if opts[:dataset] && !opts[:dataset].start_with?("#{opts[:name]}/")
        return error("dataset '#{opts[:dataset]}' is not from zpool '#{opts[:name]}'")
      end

      pool = Pool.new(opts[:name], opts[:dataset])
      return error('pool already exists') if DB::Pools.contains?(pool.name)

      pool.exclusively do
        props = ["#{Pool::PROPERTY_ACTIVE}=yes"]
        props << "#{Pool::PROPERTY_DATASET}=\"#{opts[:dataset]}\"" if opts[:dataset]

        zfs(:set, props.join(' '), pool.name)
        OsUp.init(pool.name, force: true)
        pool.setup

        DB::Pools.add(pool)
      end

      ok
    end
  end
end
