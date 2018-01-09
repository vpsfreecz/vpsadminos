module OsCtld
  class Commands::Container::Unset < Commands::Base
    handle :ct_unset

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.exclusively do
        changes = {}

        %i(hostname).each do |attr|
          changes[attr] = opts[attr]
        end

        ct.unset(changes)
        ok
      end
    end
  end
end
