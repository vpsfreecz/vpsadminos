require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::Assets < Commands::Base
    handle :id_range_assets

    include Utils::Assets

    def execute
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      error!('id range not found') unless range

      ok(list_and_validate_assets(range))
    end
  end
end
