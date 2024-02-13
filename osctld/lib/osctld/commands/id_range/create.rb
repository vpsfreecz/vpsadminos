require 'osctld/commands/logged'

module OsCtld
  class Commands::IdRange::Create < Commands::Logged
    handle :id_range_create

    def find
      pool = if opts[:pool]
               if opts[:pool].is_a?(Pool)
                 opts[:pool]
               else
                 DB::Pools.find(opts[:pool])
               end

             else
               DB::Pools.get_or_default(nil)
             end

      pool || error!('pool not found')
    end

    def execute(pool)
      if opts[:start_id] < 65_536
        error!('start_id should be greater than 65535')
      elsif opts[:block_size] < 65_536
        error!('block_size should be greater than 65535')
      elsif opts[:block_count] < 1
        error!('block_count should be greater than 1')
      end

      DB::IdRanges.sync do
        if DB::IdRanges.find(opts[:name], pool)
          error!('id range already exists')
        end

        range = IdRange.new(pool, opts[:name], load: false)
        range.configure(opts[:start_id], opts[:block_size], opts[:block_count])

        DB::IdRanges.add(range)
        ok
      end
    end
  end
end
