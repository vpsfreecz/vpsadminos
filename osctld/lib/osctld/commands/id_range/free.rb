require 'osctld/commands/logged'

module OsCtld
  class Commands::IdRange::Free < Commands::Logged
    handle :id_range_free

    def find
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      range || error!('id range not found')
    end

    def execute(range)
      if opts[:block_index]
        range.free_at(opts[:block_index])
      elsif opts[:owner]
        range.free_by(opts[:owner])
      end

      ok
    rescue IdRange::AllocationError => e
      error(e.message)
    end
  end
end
