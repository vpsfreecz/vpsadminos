module OsCtld
  class Commands::Repository::Assets < Commands::Base
    handle :repo_assets

    include Utils::Assets

    def execute
      repo = DB::Repositories.find(opts[:name], opts[:pool])
      return error('repository not found') unless repo

      ok(list_and_validate_assets(repo))
    end
  end
end
