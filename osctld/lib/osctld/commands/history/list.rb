module OsCtld
  class Commands::History::List < Commands::Base
    handle :history_list

    def execute
      ok(merge(pools.map { |p| [p, History.read(p)] }))
    end

    protected
    def pools
      if opts[:pools]
        opts[:pools].map do |name|
          DB::Pools.find(name) || (raise CommandFailed, "pool #{name} not found")
        end

      else
        DB::Pools.get
      end
    end

    def merge(readers)
      ret = []

      readers.each do |pool, reader|
        reader.entries.each do |event|
          event[:pool] = pool.name
          ret << event
        end
      end

      ret.sort { |a, b| a[:time] <=> b[:time] }
    end
  end
end
