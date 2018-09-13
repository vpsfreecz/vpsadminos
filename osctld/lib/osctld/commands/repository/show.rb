require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::Show < Commands::Base
    handle :repo_show

    def execute
      repo = DB::Repositories.find(opts[:name], opts[:pool])
      error!('repository not found') unless repo

      repo.inclusively do
        ok({
          pool: repo.pool.name,
          name: repo.name,
          url: repo.url,
          enabled: repo.enabled?,
        }.merge!(repo.attrs.export))
      end
    end
  end
end
