require 'osctld/commands/logged'

module OsCtld
  class Commands::Repository::Add < Commands::Logged
    handle :repo_add

    def find
      pool = if opts[:pool]
               if opts[:pool].is_a?(Pool)
                 opts[:pool]
               else
                 DB::Pools.find(opts[:pool])
               end

             else
               DB::Pools.get_or_default(nil)
             end

      pool || error!('pool not found')
    end

    def execute(pool)
      DB::Repositories.sync do
        if DB::Repositories.find(opts[:name], pool)
          next error('repository already exists')
        end

        repo = Repository.new(pool, opts[:name], load: false)
        repo.configure(opts[:url])

        Dir.mkdir(repo.cache_path, 0o700)
        File.chown(Repository::UID, 0, repo.cache_path)

        DB::Repositories.add(repo)
        ok
      end
    end
  end
end
