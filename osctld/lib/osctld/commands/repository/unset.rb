require 'osctld/commands/logged'

module OsCtld
  class Commands::Repository::Unset < Commands::Logged
    handle :repo_unset

    def find
      repo = DB::Repositories.find(opts[:name], opts[:pool])
      repo || error!('repository not found')
    end

    def execute(repo)
      manipulate(repo) do
        changes = {}

        opts.each do |k, v|
          case k
          when :attrs
            changes[k] = v
          end
        end

        repo.unset(changes) if changes.any?
      end

      ok
    end
  end
end
