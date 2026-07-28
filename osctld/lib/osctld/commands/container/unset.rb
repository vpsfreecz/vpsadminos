require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Unset < Commands::Logged
    handle :ct_unset

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        changes = {}

        %i[
          autostart ephemeral hostname dns_resolvers nesting cpu_package
          seccomp_profile init_cmd start_menu impermanence raw_lxc attrs
        ].each do |attr|
          changes[attr] = opts[attr] if opts.has_key?(attr)
        end

        begin
          ct.unset(changes)
        rescue DistConfig::ApplyError => e
          log_history(ct.pool)
          next error(e.message)
        end

        ok
      end
    end
  end
end
