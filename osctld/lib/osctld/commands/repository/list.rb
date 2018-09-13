require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::List < Commands::Base
    handle :repo_list

    def execute
      ok(
        DB::Repositories.get.select do |repo|
          opts[:pool] ? opts[:pool] == repo.pool.name : true

        end.map do |repo|
          {
            pool: repo.pool.name,
            name: repo.name,
            url: repo.url,
            enabled: repo.enabled?,
          }.merge!(repo.attrs.export)
        end
      )
    end
  end
end
