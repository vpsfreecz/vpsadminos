require 'osctld/commands/logged'

module OsCtld
  class Commands::IdRange::Delete < Commands::Logged
    handle :id_range_delete

    def find
      DB::IdRanges.find(opts[:name], opts[:pool])
    end

    def execute(range)
      manipulate(range) do
        unless range.can_delete?
          error!('unable to delete, ID range is in use')
        end

        File.unlink(range.config_path)
        DB::IdRanges.remove(range)
      end

      ok
    end
  end
end
