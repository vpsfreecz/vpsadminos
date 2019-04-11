require 'osctld/db/pooled_list'

module OsCtld
  class DB::IdRanges < DB::PooledList
    def self.setup(pool)
      range = IdRange.new(pool, 'default')
      add(range)

    rescue Errno::ENOENT
      start_id = 1_000_000
      block_size = 65536

      Commands::IdRange::Create.run!(
        pool: pool,
        name: 'default',
        start_id: start_id,
        block_size: block_size,
        block_count: (2**32 - start_id) / block_size,
      )
    end
  end
end
