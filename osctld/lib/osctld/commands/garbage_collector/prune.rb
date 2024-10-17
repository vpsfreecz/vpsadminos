require 'osctld/commands/base'

module OsCtld
  class Commands::GarbageCollector::Prune < Commands::Base
    handle :garbage_collector_prune

    def execute
      pools.each { |pool| pool.garbage_collector.prune }
      ok
    end

    protected

    def pools
      if opts[:pools]
        opts[:pools].map do |name|
          DB::Pools.find(name) || error!("pool #{name} not found")
        end

      else
        DB::Pools.get
      end
    end
  end
end
