require 'osctld/commands/base'

module OsCtld
  class Commands::IdRange::TableList < Commands::Base
    handle :id_range_table_list

    def execute
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      error!('id range not found') unless range

      ret =
        case opts[:type]
        when nil, 'all'
          range.export_all

        when 'allocated'
          range.export_allocated

        when 'free'
          range.export_free
        end

      ok(ret)
    end
  end
end
