require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::TableShow < Commands::Base
    handle :id_range_table_show

    def execute
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      error!('id range not found') unless range

      if opts[:block_index] < 0 || opts[:block_index] >= range.block_count
        error!('block_index out of range')
      end

      ok(range.export_at(opts[:block_index]))
    end
  end
end
