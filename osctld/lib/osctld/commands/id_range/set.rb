require 'osctld/commands/logged'

module OsCtld
  class Commands::IdRange::Set < Commands::Logged
    handle :id_range_set

    def find
      range = DB::IdRanges.find(opts[:name], opts[:pool])
      range || error!('id range not found')
    end

    def execute(range)
      manipulate(range) do
        changes = {}

        opts.each do |k, v|
          case k
          when :attrs
            changes[k] = v
          end
        end

        range.set(changes) if changes.any?
      end

      ok
    end
  end
end
