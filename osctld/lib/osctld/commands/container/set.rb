module OsCtld
  class Commands::Container::Set < Commands::Base
    handle :ct_set

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.exclusively do
        changes = {}

        %i(hostname dns_resolvers nesting).each do |attr|
          next unless opts.has_key?(attr)
          changes[attr] = opts[attr] if opts[attr] != ct.send(attr)
        end

        ct.set(changes)
        ok
      end
    end
  end
end
