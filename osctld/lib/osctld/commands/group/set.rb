require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::Set < Commands::Logged
    handle :group_set

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      manipulate(grp) do
        changes = {}

        opts.each do |k, v|
          case k
          when :attrs
            changes[k] = v
          end
        end

        grp.set(changes) if changes.any?
      end

      ok
    end
  end
end
