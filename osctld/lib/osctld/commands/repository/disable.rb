require 'osctld/commands/logged'

module OsCtld
  class Commands::Repository::Disable < Commands::Logged
    handle :repo_disable

    def find
      DB::Repositories.find(opts[:name], opts[:pool])
    end

    def execute(repo)
      manipulate(repo) do
        repo.disable
        ok
      end
    end
  end
end
