require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Set < Commands::Logged
    handle :ct_set

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        changes = {}

        %i(autostart hostname dns_resolvers nesting distribution
           seccomp_profile attrs).each do |attr|
          next unless opts.has_key?(attr)
          changes[attr] = opts[attr] if opts[attr] != ct.send(attr)
        end

        ct.set(changes)
        ok
      end
    end
  end
end
