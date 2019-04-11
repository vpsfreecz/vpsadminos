require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::Show < Commands::Base
    handle :id_range_show

    def execute
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      error!('id range not found') unless range

      ok(range.export)
    end
  end
end
