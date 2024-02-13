require 'osctld/commands/base'

module OsCtld
  class Commands::TrashBin::Prune < Commands::Base
    handle :trash_bin_prune

    def execute
      pools.each { |pool| pool.trash_bin.prune }
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
