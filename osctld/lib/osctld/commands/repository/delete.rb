module OsCtld
  class Commands::Repository::Delete < Commands::Logged
    handle :repo_delete

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      DB::Repositories.find(opts[:name], opts[:pool])
    end

    def execute(repo)
      if repo.name == 'default'
        error!('the default repository cannot be deleted, only disabled')
      end

      repo.exclusively do
        syscmd("rm -rf #{repo.cache_dir}")
        DB::Repositories.remove(repo)
      end

      ok
    end
  end
end
