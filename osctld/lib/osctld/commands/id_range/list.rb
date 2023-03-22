require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::List < Commands::Base
    handle :id_range_list

    def execute
      ret = []

      DB::IdRanges.each_by_ids(opts[:names], opts[:pool]) do |range|
        ret << range.export
      end

      ok(ret)
    end
  end
end
