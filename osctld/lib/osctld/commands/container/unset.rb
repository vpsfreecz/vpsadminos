require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Unset < Commands::Logged
    handle :ct_unset

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        changes = {}

        %i(autostart hostname dns_resolvers).each do |attr|
          changes[attr] = opts[attr]
        end

        ct.unset(changes)
        ok
      end
    end
  end
end
