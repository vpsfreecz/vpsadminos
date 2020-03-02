require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Set < Commands::Logged
    handle :ct_set

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        changes = {}

        %i(autostart ephemeral hostname dns_resolvers nesting distribution
           seccomp_profile init_cmd raw_lxc attrs).each do |attr|
          next unless opts.has_key?(attr)

          if ct.respond_to?(attr)
            changes[attr] = opts[attr] if opts[attr] != ct.send(attr)
          else
            changes[attr] = opts[attr]
          end
        end

        ct.set(changes)
        ok
      end
    end
  end
end
