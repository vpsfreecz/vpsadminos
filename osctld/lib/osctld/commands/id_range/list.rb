require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::List < Commands::Base
    handle :id_range_list

    def execute
      ret = []

      DB::IdRanges.get.each do |range|
        next if opts[:pool] && !opts[:pool].include?(range.pool.name)
        next if opts[:names] && !opts[:names].include?(range.name)

        ret << range.export
      end

      ok(ret)
    end
  end
end
