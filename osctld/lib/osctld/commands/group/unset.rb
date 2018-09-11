require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::Unset < Commands::Logged
    handle :group_unset

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      grp.exclusively do
        changes = {}

        opts.each do |k, v|
          case k
          when :attrs
            changes[k] = v
          end
        end

        grp.unset(changes) if changes.any?
      end

      ok
    end
  end
end
