module OsCtld
  class Commands::Repository::Enable < Commands::Logged
    handle :repo_enable

    def find
      DB::Repositories.find(opts[:name], opts[:pool])
    end

    def execute(repo)
      repo.exclusively do
        repo.enable
        ok
      end
    end
  end
end
