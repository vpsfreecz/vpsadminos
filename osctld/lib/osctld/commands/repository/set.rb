require 'osctld/commands/logged'

module OsCtld
  class Commands::Repository::Set < Commands::Logged
    handle :repo_set

    def find
      repo = DB::Repositories.find(opts[:name], opts[:pool])
      repo || error!('repository not found')
    end

    def execute(repo)
      repo.exclusively do
        changes = {}

        opts.each do |k, v|
          case k
          when :url, :attrs
            changes[k] = v
          end
        end

        repo.set(changes) if changes.any?
      end

      ok
    end
  end
end
