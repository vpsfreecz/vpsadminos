require 'osctld/commands/logged'

module OsCtld
  class Commands::IdRange::Allocate < Commands::Logged
    handle :id_range_allocate

    def find
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      range || error!('id range not found')
    end

    def execute(range)
      if opts[:block_count] < 1
        error!('block_count has to be greater than 1')
      end

      ok(range.allocate(
        opts[:block_count],
        block_index: opts[:block_index],
        owner: opts[:owner],
      ))

    rescue IdRange::AllocationError => e
      error(e.message)
    end
  end
end
